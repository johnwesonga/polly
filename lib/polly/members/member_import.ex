defmodule Polly.Members.MemberImport do
  @moduledoc "Parses, previews, and atomically commits CSV roster imports."

  require Ash.Query

  alias Polly.Members.Member
  alias Polly.Members.MemberImport.{CSVParser, Preview, Row}

  @required_headers ["name", "email"]
  @max_bytes 2_000_000
  @max_rows 5_000

  @spec preview(binary()) :: {:ok, Preview.t()} | {:error, String.t()}
  def preview(contents) when is_binary(contents) do
    with :ok <- validate_size(contents),
         :ok <- validate_utf8(contents),
         {:ok, parsed_rows} <- parse(contents),
         {:ok, headers, data_rows} <- split_rows(parsed_rows),
         {:ok, positions} <- validate_headers(headers),
         {:ok, rows} <- build_rows(data_rows, positions),
         :ok <- validate_row_count(rows) do
      {:ok, classify(rows)}
    end
  end

  @spec commit(Preview.t(), term()) ::
          {:ok, %{created_count: non_neg_integer(), skipped_count: non_neg_integer()}}
          | {:error, term()}
  def commit(%Preview{} = preview, %Polly.Accounts.User{} = actor) do
    with true <- Preview.valid?(preview),
         refreshed <- classify(Enum.map(preview.rows, &reset_row/1)),
         true <- Preview.valid?(refreshed) do
      case Polly.Repo.transaction(fn -> commit_rows(refreshed, actor) end) do
        {:ok, created_count} ->
          {:ok, %{created_count: created_count, skipped_count: refreshed.existing_count}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :invalid_preview}
    end
  end

  def commit(%Preview{}, _actor), do: {:error, :unauthorized}

  defp validate_size(contents) when byte_size(contents) > @max_bytes,
    do: {:error, "The CSV file must be no larger than 2 MB."}

  defp validate_size(_contents), do: :ok

  defp validate_utf8(contents) do
    if String.valid?(contents), do: :ok, else: {:error, "The CSV file must be valid UTF-8."}
  end

  defp parse(contents) do
    contents = String.trim_leading(contents, <<0xEF, 0xBB, 0xBF>>)
    {:ok, CSVParser.parse_string(contents, skip_headers: false)}
  rescue
    NimbleCSV.ParseError -> {:error, "The CSV file is malformed."}
  end

  defp split_rows([]), do: {:error, "The CSV file is empty."}

  defp split_rows([headers | rows]) do
    numbered_rows =
      rows
      |> Enum.with_index(2)
      |> Enum.reject(fn {fields, _row_number} -> Enum.all?(fields, &(String.trim(&1) == "")) end)

    if numbered_rows == [] do
      {:error, "The CSV file must contain at least one member row."}
    else
      {:ok, headers, numbered_rows}
    end
  end

  defp validate_headers(headers) do
    normalized = Enum.map(headers, &(String.trim(&1) |> String.downcase()))

    cond do
      length(normalized) != length(Enum.uniq(normalized)) ->
        {:error, "CSV headers must not be duplicated."}

      Enum.sort(normalized) != Enum.sort(@required_headers) ->
        {:error, "CSV headers must contain only name and email."}

      true ->
        {:ok,
         %{
           name: Enum.find_index(normalized, &(&1 == "name")),
           email: Enum.find_index(normalized, &(&1 == "email"))
         }}
    end
  end

  defp build_rows(numbered_rows, positions) do
    expected_columns = map_size(positions)

    if Enum.any?(numbered_rows, fn {fields, _number} -> length(fields) != expected_columns end) do
      {:error, "Every CSV row must have exactly two columns."}
    else
      rows =
        Enum.map(numbered_rows, fn {fields, row_number} ->
          %Row{
            row_number: row_number,
            name: fields |> Enum.at(positions.name) |> String.trim(),
            email: fields |> Enum.at(positions.email) |> String.trim() |> String.downcase(),
            classification: :new,
            errors: []
          }
        end)

      {:ok, rows}
    end
  end

  defp validate_row_count(rows) when length(rows) > @max_rows,
    do: {:error, "The CSV file cannot contain more than #{@max_rows} member rows."}

  defp validate_row_count(_rows), do: :ok

  defp classify(rows) do
    duplicate_emails =
      rows
      |> Enum.group_by(& &1.email)
      |> Enum.filter(fn {email, matches} -> email != "" and length(matches) > 1 end)
      |> MapSet.new(fn {email, _matches} -> email end)

    existing_by_email = existing_by_email()

    classified =
      Enum.map(rows, fn row ->
        errors = validation_errors(row, duplicate_emails)

        cond do
          errors != [] ->
            %{row | classification: :invalid, errors: errors}

          existing = Map.get(existing_by_email, row.email) ->
            %{row | classification: :existing, existing_name: existing.name, errors: []}

          true ->
            %{row | classification: :new, existing_name: nil, errors: []}
        end
      end)

    %Preview{
      rows: classified,
      total_count: length(classified),
      new_count: Enum.count(classified, &(&1.classification == :new)),
      existing_count: Enum.count(classified, &(&1.classification == :existing)),
      invalid_count: Enum.count(classified, &(&1.classification == :invalid))
    }
  end

  defp validation_errors(row, duplicate_emails) do
    []
    |> add_error(row.name == "", "Name is required.")
    |> add_error(String.length(row.name) > 160, "Name must be at most 160 characters.")
    |> add_error(row.email == "", "Email is required.")
    |> add_error(String.length(row.email) > 320, "Email must be at most 320 characters.")
    |> add_error(not valid_email?(row.email), "Email format is invalid.")
    |> add_error(
      MapSet.member?(duplicate_emails, row.email),
      "Email appears more than once in the file."
    )
    |> Enum.reverse()
  end

  defp add_error(errors, true, message), do: [message | errors]
  defp add_error(errors, false, _message), do: errors

  defp valid_email?(email), do: Regex.match?(~r/^[^\s]+@[^\s]+\.[^\s]+$/, email)

  defp existing_by_email do
    Member
    |> Ash.Query.filter(not is_nil(email))
    |> Ash.read!(authorize?: false)
    |> Map.new(fn member -> {String.downcase(String.trim(member.email)), member} end)
  end

  defp reset_row(row),
    do: %{row | classification: :new, existing_name: nil, errors: []}

  defp create_new_rows(rows, actor) do
    rows
    |> Enum.filter(&(&1.classification == :new))
    |> Enum.reduce_while(0, fn row, count ->
      case Ash.create(Member, %{name: row.name, email: row.email},
             actor: actor,
             context: %{audit: :skip}
           ) do
        {:ok, _member} -> {:cont, count + 1}
        {:error, error} -> Polly.Repo.rollback(error)
      end
    end)
  end

  defp commit_rows(preview, actor) do
    created_count = create_new_rows(preview.rows, actor)

    Polly.Audit.append!(%{
      action: "member_import.completed",
      actor: actor,
      target: %{type: "member_import", id: nil, label: "Member CSV import"},
      metadata: %{created_count: created_count, skipped_count: preview.existing_count}
    })

    created_count
  end
end
