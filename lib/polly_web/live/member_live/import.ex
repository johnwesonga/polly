defmodule PollyWeb.MemberLive.Import do
  use PollyWeb, :live_view

  alias Polly.Members.MemberImport
  alias Polly.Members.MemberImport.Preview

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Import members")
     |> assign(:preview, nil)
     |> assign(:preview_filename, nil)
     |> assign(:import_error, nil)
     |> assign(:upload_form, to_form(%{}, as: :import))
     |> allow_upload(:members_csv,
       accept: ~w(.csv),
       max_entries: 1,
       max_file_size: 2_000_000
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:members}>
      <section id="member-import-page">
        <div class="breadcrumb">
          <.link navigate={~p"/admin/members"}>Members</.link><span>/</span><span>Import CSV</span>
        </div>

        <div class="admin-titlebar">
          <div>
            <div class="admin-h1">Import members</div>
            <p class="admin-sub">Preview a CSV roster before creating any members.</p>
          </div>
        </div>
        <div class="laneline" style="margin-bottom:20px;"></div>

        <div class="card card-pad">
          <h3>Upload roster</h3>
          <p class="admin-sub">
            Choose one UTF-8 CSV file up to 2 MB with exactly the headers <code>name,email</code>. A maximum of 5,000 members may be imported at once.
          </p>

          <pre id="member-csv-example" class="callout">{"name,email\nJamie Rivera,jamie.rivera@example.com\n\"Morgan Lee, Jr.\",morgan.lee@example.com"}</pre>

          <.form
            for={@upload_form}
            id="member-import-upload-form"
            phx-change="validate-upload"
            phx-submit="preview"
            class="space-y-4"
          >
            <div class="fieldset">
              <label class="label" for={@uploads.members_csv.ref}>Member CSV file</label>
              <.live_file_input upload={@uploads.members_csv} class="file-input w-full" />
              <p class="poll-meta">
                The uploaded file is processed for the preview and is not retained afterward.
              </p>
            </div>

            <div
              :if={@preview_filename && @uploads.members_csv.entries == []}
              id="previewed-member-csv"
              class="callout"
            >
              <.icon name="hero-check-circle" class="size-5" />
              <span>
                Previewing <strong>{@preview_filename}</strong>. Choose another CSV above to replace it.
              </span>
            </div>

            <div :for={entry <- @uploads.members_csv.entries} id={"upload-#{entry.ref}"}>
              <div class="flex items-center justify-between gap-3">
                <span>{entry.client_name}</span>
                <button
                  id={"cancel-upload-#{entry.ref}"}
                  type="button"
                  phx-click="cancel-upload"
                  phx-value-ref={entry.ref}
                  class="btn btn-ghost btn-sm"
                >
                  Remove
                </button>
              </div>
              <p :for={error <- upload_errors(@uploads.members_csv, entry)} class="form-error">
                {upload_error_message(error)}
              </p>
            </div>

            <button
              id="preview-member-import"
              type="submit"
              class="btn btn-coral"
              disabled={@uploads.members_csv.entries == []}
            >
              Preview import
            </button>
          </.form>

          <div id="member-import-status" aria-live="polite">
            <div :if={@import_error} class="callout amber" role="alert">{@import_error}</div>
          </div>
        </div>

        <div :if={@preview} id="member-import-preview" class="card card-pad" style="margin-top:20px;">
          <div class="flex items-center justify-between gap-3">
            <h3>Import preview</h3>
            <span class={if(Preview.valid?(@preview), do: "pill open", else: "pill closed")}>
              {if(Preview.valid?(@preview), do: "Ready", else: "Needs correction")}
            </span>
          </div>

          <div id="member-import-counts" class="stats shadow-none w-full">
            <div class="stat">
              <div class="stat-title">Rows</div>
              <div class="stat-value text-2xl">{@preview.total_count}</div>
            </div>
            <div class="stat">
              <div class="stat-title">New</div>
              <div class="stat-value text-2xl">{@preview.new_count}</div>
            </div>
            <div class="stat">
              <div class="stat-title">Existing</div>
              <div class="stat-value text-2xl">{@preview.existing_count}</div>
            </div>
            <div class="stat">
              <div class="stat-title">Invalid</div>
              <div class="stat-value text-2xl">{@preview.invalid_count}</div>
            </div>
          </div>

          <div class="overflow-x-auto">
            <table id="member-import-rows" class="table">
              <thead>
                <tr>
                  <th>Row</th>
                  <th>Name</th>
                  <th>Email</th>
                  <th>Status</th>
                  <th>Details</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @preview.rows} id={"import-row-#{row.row_number}"}>
                  <td>{row.row_number}</td>
                  <td>{row.name}</td>
                  <td>{row.email}</td>
                  <td>
                    <span class={classification_class(row.classification)}>
                      {classification_label(row.classification)}
                    </span>
                  </td>
                  <td>
                    <span :if={row.classification == :existing and row.existing_name != row.name}>
                      Existing member “{row.existing_name}” will remain unchanged.
                    </span>
                    <ul :if={row.errors != []} class="list-disc pl-4">
                      <li :for={error <- row.errors}>{error}</li>
                    </ul>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <button
            id="commit-member-import"
            type="button"
            phx-click="commit"
            class="btn btn-coral"
            disabled={!Preview.valid?(@preview)}
          >
            Import {@preview.new_count} members
          </button>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate-upload", _params, socket) do
    socket =
      if socket.assigns.uploads.members_csv.entries == [] do
        socket
      else
        assign(socket, preview: nil, preview_filename: nil, import_error: nil)
      end

    {:noreply, socket}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :members_csv, ref)}
  end

  def handle_event("preview", _params, socket) do
    case uploaded_contents(socket) do
      {:ok, contents, filename} ->
        case MemberImport.preview(contents) do
          {:ok, preview} ->
            {:noreply,
             assign(socket,
               preview: preview,
               preview_filename: filename,
               import_error: nil
             )}

          {:error, message} ->
            {:noreply,
             assign(socket, preview: nil, preview_filename: filename, import_error: message)}
        end

      {:error, message} ->
        {:noreply, assign(socket, preview: nil, preview_filename: nil, import_error: message)}
    end
  end

  def handle_event("commit", _params, %{assigns: %{preview: %Preview{} = preview}} = socket) do
    case MemberImport.commit(preview, socket.assigns.current_user) do
      {:ok, result} ->
        message =
          "#{result.created_count} members imported; #{result.skipped_count} existing members skipped."

        {:noreply, socket |> put_flash(:info, message) |> push_navigate(to: ~p"/admin/members")}

      {:error, _reason} ->
        {:noreply,
         assign(
           socket,
           :import_error,
           "The import could not be completed. Preview the file again and retry."
         )}
    end
  end

  def handle_event("commit", _params, socket), do: {:noreply, socket}

  defp uploaded_contents(socket) do
    case upload_errors(socket.assigns.uploads.members_csv) do
      [] ->
        case consume_uploaded_entries(socket, :members_csv, fn %{path: path}, entry ->
               {:ok, {File.read(path), entry.client_name}}
             end) do
          [{{:ok, contents}, filename}] -> {:ok, contents, filename}
          [{{:error, _reason}, _filename}] -> {:error, "The CSV file could not be read."}
          [] -> {:error, "Choose a CSV file to preview."}
        end

      _errors ->
        {:error, "Choose a valid CSV file no larger than 2 MB."}
    end
  end

  defp upload_error_message(:too_large), do: "The CSV file must be no larger than 2 MB."
  defp upload_error_message(:not_accepted), do: "Only .csv files are accepted."
  defp upload_error_message(:too_many_files), do: "Choose only one CSV file."
  defp upload_error_message(_error), do: "The file could not be uploaded."

  defp classification_label(:new), do: "New"
  defp classification_label(:existing), do: "Existing"
  defp classification_label(:invalid), do: "Invalid"

  defp classification_class(:new), do: "pill open"
  defp classification_class(:existing), do: "pill draft"
  defp classification_class(:invalid), do: "pill closed"
end
