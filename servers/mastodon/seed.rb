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
# `reorder`, since a status is listed newest first unless told otherwise: the writer's first
# note is the oldest, however many they have written since.
first = Status.where(account: writer_account, reblog_of_id: nil).reorder(:id).first
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

# What the checks of what a Mastodon says of notices need (#323): the writer told of each kind
# of thing this seed can make happen to them, a line the server cuts at a page's edge, notices
# to spare for the checks that dismiss one, and notices held back from people the writer does
# not follow. Idempotent, as the rest is: what is there is found again, and only what a run of
# the checks used up is made anew.
require "sidekiq/api"

# **Nothing here is told of anything by itself.** The server queues the telling — a post's
# fan-out, which is where a mention and a quote are told from, and then the notice itself — and
# this server runs no worker. So the queued jobs are run here, oldest first: every one that
# tells somebody something, and the fan-out of the posts this seed names and of no other, since
# a fan-out run for every post a check ever wrote would fill the writer's home with them.
# Three passes, because a fan-out and a poll's ending each queue the telling they lead to.
telling = %w(LocalNotificationWorker PollExpirationNotifyWorker UnfilterNotificationsWorker).freeze
tell = lambda do |*posts|
  fanned = posts.map(&:id)
  3.times do
    (Sidekiq::Queue.all.flat_map(&:to_a) + Sidekiq::ScheduledSet.new.to_a)
      .select do |job|
        telling.include?(job.klass) || (job.klass == "DistributionWorker" && fanned.include?(job.args.first))
      end
      .sort_by(&:created_at)
      .each do |job|
        job.klass.constantize.new.perform(*job.args)
      rescue StandardError => e
        # Said and gone on from: a job left queued would fail every later run of this seed
        # the same way. What it would have told is missing, and the check of it says so.
        warn "seed: #{job.klass}(#{job.args.join(', ')}) failed: #{e.class}: #{e.message}"
      ensure
        job.delete
      end
  end
end

# Somebody nobody signs in as: the password is made here and kept nowhere.
person = lambda do |username|
  found = Account.find_local(username)
  next found if found
  secret = SecureRandom.hex(16)
  made = User.new(
    email: "#{username}@example.com",
    password: secret,
    password_confirmation: secret,
    confirmed_at: Time.now.utc,
    approved: true
  )
  made.account = Account.new(username: username)
  made.skip_confirmation_notification! if made.respond_to?(:skip_confirmation_notification!)
  made.save!(validate: false)
  made.approve! if made.respond_to?(:approve!) && !made.approved?
  made.account
end

# A post found again by its words, or written. Unlisted, so none of these stands in the public
# timeline the other checks read.
said = lambda do |who, words, **more|
  Status.where(account: who, reblog_of_id: nil).where("text LIKE ?", "%#{words}%").first ||
    PostStatusService.new.call(who, text: words, visibility: "unlisted", **more)
end

# A third person, whom the writer does not follow.
third = person.call("fediqo_third")

# **A line the server cuts at a page's edge.** A page of the gathered read is forty lines, and a
# line whose notices lie further apart than that comes back on the next page under the same
# key. So: one favourite of a post, then forty favourites of forty other posts — forty lines
# no check dismisses — and only then, further down, the second favourite of the first post.
cut = said.call(writer_account, "fediqo323seed cut")
FavouriteService.new.call(other, cut)
tell.call
(1..40).each { |n| FavouriteService.new.call(other, said.call(writer_account, format("fediqo323seed pad %02d", n))) }
tell.call

# Each kind this seed can cause, between the two: a mention and an answer; a post favoured and
# boosted by two people, which is a gathered line of two; a follow; a follow request, which
# only a locked account gets, so the writer is locked for the length of the asking; a poll of
# the writer's own that ended; a post the writer boosted and its author then changed; a quote.
mention = said.call(other, "@fediqo fediqo323seed mention")
answer = said.call(other, "@fediqo fediqo323seed answer", thread: first)
liked = said.call(writer_account, "fediqo323seed liked")
[other, third].each do |who|
  FavouriteService.new.call(who, liked)
  ReblogService.new.call(who, liked)
end
FollowService.new.call(third, writer_account)
unless other.requested?(writer_account)
  begin
    writer_account.update!(locked: true)
    FollowService.new.call(other, writer_account)
  ensure
    writer_account.update!(locked: false)
  end
end
# The shortest poll this server takes is five minutes long, so its end is moved to the past
# once it is made: the job that tells of the end tells nothing of a poll still open.
polled = said.call(writer_account, "fediqo323seed poll", poll: { options: %w(one two), expires_in: 300 })
polled.poll.update_columns(expires_at: 1.minute.ago) unless polled.poll.expired?
changed = said.call(other, "fediqo323seed boosted")
ReblogService.new.call(writer_account, changed)
unless changed.edited?
  UpdateStatusService.new.call(changed, other.id, text: "fediqo323seed boosted, and changed")
  changed.reload
end
quoted = said.call(writer_account, "fediqo323seed quoted")
anybody = InteractionPolicy::POLICY_FLAGS[:public] << 16
quoted.update!(quote_approval_policy: anybody) unless quoted.quote_approval_policy == anybody
quoting = said.call(other, "fediqo323seed quoting", quoted_status: quoted)
tell.call(mention, answer, changed, quoting)

FavouriteService.new.call(third, cut)
tell.call

# **Notices to spare.** A dismissal cannot be taken back, and nothing a check does makes a new
# notice on a server with no worker, so each run of the checks uses up two of these and one
# held-back request of each of two people below. Kept at four runs' worth; a `make servers`
# makes up what was used.
runs = 4
spared = lambda do |posts|
  favourites = Favourite.where(status_id: posts.map(&:id)).select(:id)
  Notification.where(account: writer_account, activity_type: "Favourite", activity_id: favourites)
end
spares = Status.where(account: writer_account).where("text LIKE ?", "fediqo323seed spare %").to_a
[runs * 2 - spared.call(spares).count, 0].max.times do
  spares << PostStatusService.new.call(writer_account, text: format("fediqo323seed spare %03d", spares.size + 1), visibility: "unlisted")
  FavouriteService.new.call(other, spares.last)
end
tell.call

# **What the server holds back.** An account as it is made holds back a private mention from
# somebody its owner does not follow, so a stranger writing to the writer alone is one request
# waiting. Each is somebody new: one let through is never held back again.
waiting = -> { NotificationRequest.where(account: writer_account).includes(:from_account, :last_status).order(:id).to_a }
strangers = Account.where(domain: nil).where("username LIKE ?", "fediqo\\_stranger\\_%").count
whispers = (1..[runs * 2 - waiting.call.size, 0].max).map do |n|
  stranger = person.call("fediqo_stranger_#{strangers + n}")
  PostStatusService.new.call(stranger, text: "@fediqo fediqo323seed held", visibility: "direct")
end
tell.call(*whispers)

# The writer's sign-ins as this app makes them, word for word (`MastodonOAuth.scopes`): one
# made before notices were asked for, reading and acting, and one made since, each. An app of
# their own, so the sign-in found again above is never one of these.
grained = Doorkeeper::Application.find_or_create_by!(name: "fediqo-servers-notices") do |record|
  record.redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
  record.scopes = "read write"
end
reading = "read:statuses read:lists read:accounts read:search"
acting = "#{reading} write:statuses write:favourites write:bookmarks"
sign_ins = {
  "reading" => reading,
  "acting" => acting,
  "noticing" => "#{reading} read:notifications",
  "dismissing" => "#{acting} read:notifications write:notifications"
}.transform_values do |scopes|
  held = Doorkeeper::AccessToken.find_by(application: grained, resource_owner_id: user.id, scopes: scopes, revoked_at: nil) ||
    Doorkeeper::AccessToken.create!(application: grained, resource_owner_id: user.id, scopes: scopes, expires_in: nil)
  { "token" => held.token, "scopes" => scopes }
end
# And this app as it would register itself to ask for notices on top of reading and acting,
# for the check that signs in through the server's own page. Made here and not by the check:
# this server takes five registrations in ten minutes from anywhere, and the other checks make
# two a run. The server holds a registration made here to the scopes it knows, as it does one
# made through its API.
asking = Doorkeeper::Application.find_or_create_by!(name: "fediqo-servers-notices-ask") do |record|
  record.redirect_uri = "fediqo://oauth"
  record.scopes = sign_ins["dismissing"]["scopes"]
end

more = "/tmp/fediqo-mastodon-tokens.json"
File.write(more, JSON.generate(tokens.merge(
  # The sign-in page is asked by this id for a scope the registration does not include.
  "client" => full.uid,
  "seeded" => {
    "list" => list.id.to_s, "plain" => plain.id.to_s, "edited" => edited.id.to_s,
    "reblog" => reblog.id.to_s, "reblogged" => first.id.to_s
  },
  "notices" => sign_ins.merge(
    "app" => { "id" => asking.uid, "secret" => asking.secret, "scopes" => asking.scopes.to_s },
    "third" => third.username,
    "mention" => mention.id.to_s, "answer" => answer.id.to_s, "liked" => liked.id.to_s,
    "poll" => polled.id.to_s, "changed" => changed.id.to_s, "quoting" => quoting.id.to_s,
    "cut" => cut.id.to_s,
    "spare" => spared.call(spares).map { |notice| notice.target_status.id.to_s },
    "held" => waiting.call.map { |request| { "by" => request.from_account.username, "post" => request.last_status_id.to_s } }
  )
)))
puts "wrote #{more}"
