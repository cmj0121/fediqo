# Idempotent. A second `make servers` must not invent a second writer or a second note.
# Built here rather than through tootctl: this machine has no MX for a dummy
# address, and tootctl's create refuses an e-mail it cannot reach.
account = Account.find_local("fediqo")
if account.nil?
  user = User.new(
    email: "writer@example.com",
    password: "LocalOnlyPass1",
    password_confirmation: "LocalOnlyPass1",
    confirmed_at: Time.now.utc,
    approved: true
  )
  user.account = Account.new(username: "fediqo")
  user.skip_confirmation_notification! if user.respond_to?(:skip_confirmation_notification!)
  user.save!(validate: false)
  account = user.account
end
# save(validate: false) does not run the approval callbacks. A token issued
# against an unapproved login answers 403 to every write.
user = account.user
user.approve! if user.respond_to?(:approve!) && !user.approved?

if Status.where(account: account).none?
  PostStatusService.new.call(
    account,
    text: "A public note on this machine",
    visibility: "public"
  )
end

user = account.user
app = Doorkeeper::Application.find_or_create_by!(name: "fediqo-servers") do |record|
  record.redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
  record.scopes = "read write:statuses write:favourites"
end

token = Doorkeeper::AccessToken.find_or_create_by!(
  application: app,
  resource_owner_id: user.id
) do |record|
  record.scopes = "read write:statuses write:favourites"
  record.expires_in = nil
end

path = "/tmp/fediqo-mastodon-token"
File.write(path, token.token)
puts "wrote #{path}"

# What the checks of what a Mastodon says need beyond one writer (#298): a second person, so
# there is somebody whose post the first may not see and somebody to reblog and answer; and a
# sign-in of each that may do everything a person can, beside the first one above, which may
# not bookmark. Idempotent, as the rest is.
other = Account.find_local("fediqo_other")
if other.nil?
  other_user = User.new(
    email: "other@example.com",
    password: "LocalOnlyPass2",
    password_confirmation: "LocalOnlyPass2",
    confirmed_at: Time.now.utc,
    approved: true
  )
  other_user.account = Account.new(username: "fediqo_other")
  other_user.skip_confirmation_notification! if other_user.respond_to?(:skip_confirmation_notification!)
  other_user.save!(validate: false)
  other = other_user.account
end
other_user = other.user
other_user.approve! if other_user.respond_to?(:approve!) && !other_user.approved?

full = Doorkeeper::Application.find_or_create_by!(name: "fediqo-servers-full") do |record|
  record.redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
  record.scopes = "read write"
end

tokens = { "writer" => user, "other" => other_user }.transform_values do |owner|
  Doorkeeper::AccessToken.find_or_create_by!(application: full, resource_owner_id: owner.id) do |record|
    record.scopes = "read write"
    record.expires_in = nil
  end.token
end

# What a read of Home, of a list and of what is rising brings. **Put there by hand**: this
# server runs no background worker, so nothing fans a post out to a home or a list by itself,
# and nothing ranks one. The writer follows the other person and has them in a list; that
# person has a post never changed, one changed once, and a reblog of the writer's first note;
# each is pushed into the writer's home and the list, and the changed one is made to be rising.
writer_account = account
writer_account.follow!(other) unless writer_account.following?(other)
list = List.find_or_create_by!(account: writer_account, title: "fediqo-298")
ListAccount.find_or_create_by!(list: list, account: other)
plain = Status.where(account: other).where("text LIKE ?", "%fediqo298seed plain%").first ||
  PostStatusService.new.call(other, text: "fediqo298seed plain", visibility: "public")
edited = Status.where(account: other).where("text LIKE ?", "%fediqo298seed%").where.not(id: plain.id)
  .where(reblog_of_id: nil).first ||
  PostStatusService.new.call(other, text: "fediqo298seed before", visibility: "public")
unless edited.text.include?("fediqo298seed edited")
  UpdateStatusService.new.call(edited, other.id, text: "fediqo298seed edited")
  edited.reload
end
first = Status.where(account: writer_account, reblog_of_id: nil).order(:id).first
reblog = Status.where(account: other, reblog_of_id: first.id).first || ReblogService.new.call(other, first)
# **A home is kept only for somebody who has signed in lately**: this server pushes nothing to
# the home of a person it has not seen (`FeedManager#push_to_home`), and on a server just made
# the writer has never been seen. So they are marked as signed in first — which may start the
# rebuilding of their home that no worker here will ever finish, so that is marked finished.
user.update_sign_in!(new_sign_in: true) unless user.signed_in_recently?
HomeFeed.new(writer_account).regeneration_finished! if HomeFeed.new(writer_account).regenerating?
[plain, edited, reblog].each do |status|
  FeedManager.instance.push_to_home(writer_account, status) ||
    FeedManager.instance.redis.zscore(FeedManager.instance.key(:home, writer_account.id), status.id) ||
    raise("the seed could not put status #{status.id} in the writer's home")
  FeedManager.instance.push_to_list(list, status)
end
trend = StatusTrend.find_or_initialize_by(status_id: edited.id)
trend.assign_attributes(account_id: edited.account_id, score: 5.0, rank: 1, allowed: true, language: edited.language)
trend.save!

more = "/tmp/fediqo-mastodon-tokens.json"
File.write(more, JSON.generate(tokens.merge(
  # The sign-in page is asked by this id for a scope the registration does not include.
  "client" => full.uid,
  "seeded" => {
    "list" => list.id.to_s, "plain" => plain.id.to_s, "edited" => edited.id.to_s,
    "reblog" => reblog.id.to_s, "reblogged" => first.id.to_s
  }
)))
puts "wrote #{more}"
