defmodule Polly.Accounts.AuthorizationCoverage do
  @moduledoc """
  Phase 0 inventory of Polly's authorization boundaries.

  This module is deliberately data-only. It records the permission enforced at
  each boundary and keeps trusted authorization bypasses visible during review.
  The accompanying test detects unreviewed Ash actions and bypasses.
  """

  @permissions Polly.Accounts.Authorization.permissions()

  @spec permissions() :: [atom()]
  def permissions, do: @permissions

  @doc "Returns protected web entry points and their intended permissions."
  def web_boundaries do
    %{
      PollyWeb.AdminLive => {:any, @permissions -- [:operate_jobs]},
      PollyWeb.AdministratorLive => {:permission, :manage_administrators},
      PollyWeb.AdministratorInvitationLive =>
        {:trusted, "signed administrator invitation credential"},
      PollyWeb.AuditLive => {:permission, :view_audit},
      PollyWeb.MemberLive.Index => {:permission, :manage_members},
      PollyWeb.MemberLive.Import => {:permission, :manage_members},
      PollyWeb.PollLive.Index => {:any, [:manage_polls, :view_results]},
      PollyWeb.PollLive.Form => {:permission, :manage_polls},
      PollyWeb.PollLive.Duplicate => {:permission, :manage_polls},
      PollyWeb.PollLive.Options => {:permission, :manage_polls},
      PollyWeb.PollLive.Electorate => {:permission, :manage_electorates},
      PollyWeb.PollLive.Access =>
        {:all, [:manage_access_grants], event_permissions: [send: :send_invitations]},
      PollyWeb.PollLive.Results =>
        {:all, [:view_results],
         event_permissions: [
           {:open, :manage_polls},
           {:publish, :publish_results},
           {:export, :export_results},
           {:"make-results-public", :publish_results},
           {:"make-results-credentialed", :publish_results}
         ]},
      PollyWeb.PublicPollResultsLive =>
        {:trusted, "closed, published poll explicitly configured for public results"},
      PollyWeb.PollResultsExportController => {:permission, :export_results},
      PollyWeb.ObanWebResolver => {:permission, :view_jobs}
    }
  end

  @doc "Returns Ash actions and their intended permission or trusted boundary."
  def resource_actions do
    %{
      Polly.Accounts.User => %{
        confirm: {:trusted, "signed confirmation credential"},
        log_out_everywhere: {:trusted, "authenticated user's own session lifecycle"},
        sign_in_with_remember_me: {:trusted, "authentication entry point"},
        read: {:permission, :manage_administrators},
        get_by_subject: {:trusted, "authentication subject loading"},
        change_password: {:trusted, "authenticated user's own credential"},
        sign_in_with_password: {:trusted, "authentication entry point"},
        sign_in_with_token: {:trusted, "signed authentication credential"},
        register_with_password: {:trusted, "bootstrap and invitation acceptance only"},
        accept_administrator_invitation: {:trusted, "validated invitation acceptance service"},
        request_password_reset_token: {:trusted, "non-enumerating authentication entry point"},
        get_by_email: {:trusted, "authentication and administrator lifecycle lookup"},
        reset_password_with_token: {:trusted, "signed password-reset credential"},
        recover_owner: {:trusted, "release-shell final-owner recovery"},
        update_account_lifecycle: {:trusted, "owner-authorized lifecycle service"}
      },
      Polly.Accounts.Token => %{
        store_confirmation_changes: {:trusted, "authentication token storage"},
        get_confirmation_changes: {:trusted, "authentication token verification"},
        read_expired: {:trusted, "authentication token maintenance"},
        read: {:trusted, "authentication framework storage"},
        expired: {:trusted, "authentication token maintenance"},
        get_token: {:trusted, "authentication token verification"},
        revoked?: {:trusted, "authentication token verification"},
        revoke_token: {:trusted, "authentication token lifecycle"},
        revoke_jti: {:trusted, "authentication token lifecycle"},
        store_token: {:trusted, "authentication token storage"},
        expunge_expired: {:trusted, "authentication token maintenance"},
        revoke_all_stored_for_subject: {:trusted, "account disable and session lifecycle"}
      },
      Polly.Accounts.AdministratorInvitation => %{
        read: {:permission, :manage_administrators},
        invite: {:trusted, "owner-authorized invitation service"},
        record_delivery: {:trusted, "administrator invitation Oban worker"},
        revoke: {:trusted, "owner-authorized invitation service"},
        expire: {:trusted, "administrator invitation lifecycle"},
        accept: {:trusted, "validated invitation acceptance transaction"}
      },
      Polly.Members.Member => %{
        read: {:permission, :manage_members},
        create: {:permission, :manage_members},
        update: {:permission, :manage_members}
      },
      Polly.Polls.Poll => %{
        read: {:any, [:manage_polls, :view_results]},
        create_draft: {:permission, :manage_polls},
        update_draft: {:permission, :manage_polls},
        open: {:permission, :manage_polls},
        close: {:permission, :publish_results},
        publish_results: {:permission, :publish_results},
        make_results_public: {:permission, :publish_results},
        make_results_credentialed: {:permission, :publish_results}
      },
      Polly.Polls.Option => %{
        read: {:any, [:manage_polls, :view_results]},
        create: {:permission, :manage_polls},
        update: {:permission, :manage_polls},
        destroy: {:permission, :manage_polls}
      },
      Polly.Polls.Eligibility => %{
        read: {:permission, :manage_electorates},
        create: {:permission, :manage_electorates},
        destroy: {:permission, :manage_electorates}
      },
      Polly.Polls.AccessGrant => %{
        read: {:permission, :manage_access_grants},
        resolve: {:trusted, "unguessable voter access credential"},
        issue: {:permission, :manage_access_grants},
        revoke: {:permission, :manage_access_grants}
      },
      Polly.Polls.Ballot => %{
        read: {:permission, :view_results},
        submit: {:trusted, "validated voter access grant"}
      },
      Polly.Polls.Selection => %{
        read: {:permission, :view_results},
        select: {:trusted, "validated ballot submission"}
      },
      Polly.Polls.InvitationDelivery => %{
        read: {:any, [:send_invitations, :view_results, :view_jobs]},
        queue: {:permission, :send_invitations},
        record_attempt: {:trusted, "Oban invitation worker"},
        accept: {:trusted, "Oban invitation worker"},
        fail: {:trusted, "Oban invitation worker"},
        cancel: {:trusted, "Oban invitation worker"}
      },
      Polly.Audit.Event => %{
        read: {:permission, :view_audit},
        append: {:trusted, "authorized domain action audit hook"}
      }
    }
  end

  @doc "Returns context entry points that require independent permission checks."
  def service_boundaries do
    %{
      {Polly.Members.MemberImport, :preview} => {:permission, :manage_members},
      {Polly.Accounts.Administrators, :disable} => {:permission, :manage_administrators},
      {Polly.Accounts.Administrators, :enable} => {:permission, :manage_administrators},
      {Polly.Accounts.Administrators, :change_role} => {:permission, :manage_administrators},
      {Polly.Accounts.AdministratorInvitations, :invite} => {:permission, :manage_administrators},
      {Polly.Accounts.AdministratorInvitations, :resend} => {:permission, :manage_administrators},
      {Polly.Accounts.AdministratorInvitations, :renew} => {:permission, :manage_administrators},
      {Polly.Accounts.AdministratorInvitations, :revoke} => {:permission, :manage_administrators},
      {Polly.Accounts.AdministratorInvitations, :accept} =>
        {:trusted, "signed administrator invitation credential"},
      {Polly.Accounts.AdministratorInvitations, :verify} =>
        {:trusted, "signed administrator invitation credential"},
      {Polly.Administration.Dashboard, :load} => {:permission, :view_results},
      {Polly.Members.MemberImport, :commit} => {:permission, :manage_members},
      {Polly.Polls.Options, :reorder} => {:permission, :manage_polls},
      {Polly.Polls.Invitations, :preview} => {:permission, :send_invitations},
      {Polly.Polls.Invitations, :enqueue_bulk} => {:permission, :send_invitations},
      {Polly.Polls.Invitations, :enqueue_one} => {:permission, :send_invitations},
      {Polly.Polls.Duplicator, :duplicate} => {:permission, :manage_polls},
      {Polly.Polls.Duplicator, :preview} => {:permission, :manage_polls},
      {Polly.Polls.Electorate, :include_member} => {:permission, :manage_electorates},
      {Polly.Polls.Electorate, :reissue} => {:permission, :manage_access_grants},
      {Polly.Polls.Electorate, :issue} => {:permission, :manage_access_grants},
      {Polly.Polls.Electorate, :revoke} => {:permission, :manage_access_grants},
      {Polly.Polls.Results, :for_poll} => {:permission, :view_results},
      {Polly.Polls.PublicResults, :fetch_by_slug} =>
        {:trusted, "closed, published poll explicitly configured for public results"},
      {Polly.Polls.Readiness, :attention_counts} => {:permission, :view_results},
      {Polly.Polls.ResultExport, :generate} => {:permission, :export_results},
      {Polly.Polls.Ballots, :submit} => {:trusted, "public voting credential flow"},
      {Polly.Audit, :append} => {:trusted, "authorized domain action audit hook"}
    }
  end

  @doc "Returns reviewed uses of `authorize?: false`, grouped by source file."
  def authorization_bypasses do
    %{
      "lib/mix/tasks/polly.admin.create.ex" => %{
        count: 1,
        reason: "trusted release-shell administrator bootstrap"
      },
      "lib/mix/tasks/polly.admin.promote_owner.ex" => %{
        count: 2,
        reason: "trusted release-shell final-owner recovery"
      },
      "lib/polly/accounts/administrators.ex" => %{
        count: 5,
        reason: "owner-authorized lifecycle transaction, token revocation, and session checks"
      },
      "lib/polly/accounts/administrator_invitation_worker.ex" => %{
        count: 7,
        reason: "trusted Oban worker processing an ID-only durable invitation command"
      },
      "lib/polly/accounts/administrator_invitations.ex" => %{
        count: 10,
        reason: "owner-authorized creation and signed public acceptance transactions"
      },
      "lib/polly/members/member_import.ex" => %{
        count: 1,
        reason: "duplicate lookup inside an actor-gated import"
      },
      "lib/polly/polls/ballots.ex" => %{
        count: 5,
        reason: "public voting flow after access-grant validation"
      },
      "lib/polly/polls/access_grant.ex" => %{
        count: 1,
        reason: "public credential resolution constrained by digest and grant lifecycle filters"
      },
      "lib/polly/polls/invitation_worker.ex" => %{
        count: 10,
        reason: "trusted Oban worker processing an authorized durable command"
      },
      "lib/polly/polls/results.ex" => %{
        count: 5,
        reason: "aggregate result builder called from protected boundaries"
      },
      "lib/polly/polls/public_results.ex" => %{
        count: 1,
        reason: "aggregate-only projection after closed, published, public visibility filtering"
      },
      "lib/polly/polls/readiness.ex" => %{
        count: 2,
        reason: "shared invariant queries used by authorized poll actions"
      },
      "lib/polly/polls/slug.ex" => %{
        count: 1,
        reason: "internal uniqueness check used by poll changes"
      },
      "lib/polly/polls/validations/member_is_eligible.ex" => %{
        count: 1,
        reason: "invariant query within a validated ballot submission"
      },
      "lib/polly/polls/validations/poll_is_draft.ex" => %{
        count: 1,
        reason: "invariant query within an authorized poll action"
      },
      "lib/polly_web/live/poll_live/vote.ex" => %{
        count: 3,
        reason: "public voting UI after access-token resolution"
      }
    }
  end
end
