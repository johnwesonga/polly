defmodule PollyWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PollyWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :active_nav, :atom,
    default: nil,
    values: [nil, :overview, :members, :polls, :administrators, :audit, :jobs],
    doc: "the active administrator navigation item"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%= if @current_scope do %>
      <div id="admin-shell" class="admin-layout">
        <nav id="admin-navigation" class="admin-nav" aria-label="Administrator navigation">
          <.link navigate={~p"/admin"} class="navhead brand-link">
            <span class="sq" aria-hidden="true"></span>
            <span>Touchpad</span>
          </.link>
          <.link
            id="admin-nav-overview"
            navigate={~p"/admin"}
            class={if(@active_nav == :overview, do: "current", else: nil)}
          >
            Overview
          </.link>
          <.link
            :if={allowed?(@current_scope.user, :manage_members)}
            id="admin-nav-members"
            navigate={~p"/admin/members"}
            class={if(@active_nav == :members, do: "current", else: nil)}
          >
            Members
          </.link>
          <.link
            :if={
              allowed?(@current_scope.user, :manage_polls) ||
                allowed?(@current_scope.user, :view_results)
            }
            id="admin-nav-polls"
            navigate={~p"/admin/polls"}
            class={if(@active_nav == :polls, do: "current", else: nil)}
          >
            Polls
          </.link>
          <.link
            :if={allowed?(@current_scope.user, :manage_administrators)}
            id="admin-nav-administrators"
            navigate={~p"/admin/administrators"}
            class={if(@active_nav == :administrators, do: "current", else: nil)}
          >
            Administrators
          </.link>
          <.link
            :if={allowed?(@current_scope.user, :view_audit)}
            id="admin-nav-audit"
            navigate={~p"/admin/audit"}
            class={if(@active_nav == :audit, do: "current", else: nil)}
          >
            Audit trail
          </.link>
          <.link
            :if={allowed?(@current_scope.user, :view_jobs)}
            id="admin-nav-background-jobs"
            href={~p"/admin/oban"}
            class={if(@active_nav == :jobs, do: "current", else: nil)}
          >
            Background jobs
          </.link>
          <div class="navfoot">
            Signed in as<br />
            <strong>{to_string(@current_scope.user.email)}</strong>
            <br />
            <.link href={~p"/sign-out"} class="mt-2 inline-block text-white underline">
              Sign out
            </.link>
          </div>
        </nav>

        <main class="admin-main">
          <div class="admin-content">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    <% else %>
      <header class="navbar px-4 sm:px-6 lg:px-8">
        <div class="flex-1">
          <a href="/" class="brand">
            <span class="brand-mark" aria-hidden="true"></span>
            <span class="brand-name">Touchpad</span>
          </a>
        </div>
        <.theme_toggle />
      </header>

      <main class="px-4 py-20 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-2xl space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  defp allowed?(user, permission), do: Polly.Accounts.Authorization.allowed?(user, permission)

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
