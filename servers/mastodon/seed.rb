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
