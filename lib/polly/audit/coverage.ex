defmodule Polly.Audit.Coverage do
  @moduledoc "Maintained inventory of administrator write actions and their audit ownership."

  @inventory %{
    {Polly.Members.Member, :create} => "member.created",
    {Polly.Members.Member, :update} => "member.updated/member.activated/member.deactivated",
    {Polly.Polls.Poll, :create_draft} => "poll.created",
    {Polly.Polls.Poll, :update_draft} => "poll.updated",
    {Polly.Polls.Poll, :open} => "poll.opened",
    {Polly.Polls.Poll, :close} => "poll.closed",
    {Polly.Polls.Poll, :publish_results} => "poll.results_published",
    {Polly.Polls.Option, :create} => "poll_option.created",
    {Polly.Polls.Option, :update} => "poll_option.updated/poll_option.reordered",
    {Polly.Polls.Option, :destroy} => "poll_option.deleted",
    {Polly.Polls.Eligibility, :create} => "poll_electorate.member_added",
    {Polly.Polls.Eligibility, :destroy} => "poll_electorate.member_removed",
    {Polly.Polls.AccessGrant, :issue} =>
      "poll_access_grant.issued/poll_access_grant.reissued/poll_electorate.member_added",
    {Polly.Polls.AccessGrant, :revoke} =>
      "poll_access_grant.revoked/poll_access_grant.reissued/poll_electorate.member_removed",
    {Polly.Members.MemberImport, :commit} => "member_import.completed",
    {Polly.Polls.Duplicator, :duplicate} => "poll.duplicated",
    {Polly.Accounts.Administrators, :disable} => "administrator.disabled",
    {Polly.Accounts.Administrators, :enable} => "administrator.enabled",
    {Polly.Accounts.Administrators, :change_role} => "administrator.role_changed"
  }

  @exemptions %{
    {Polly.Polls.Ballot, :submit} => "public voter action, not administrator activity",
    {Polly.Polls.Selection, :select} => "part of public ballot submission"
  }

  def inventory, do: @inventory
  def exemptions, do: @exemptions
end
