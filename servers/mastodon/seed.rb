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
# Read by the checks on this machine and by nobody else: kept to its owner, whatever the umask.
# Written to a fresh owner-only file and moved over the old one: a file left from before at
# another mode never holds the new token, even for a moment.
owner_only = lambda do |target, contents|
  fresh = "#{target}.#{Process.pid}"
  File.open(fresh, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(contents) }
  File.rename(fresh, target)
end
owner_only.call(path, token.token)
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

# What the checks of the hashtags and the links rising need (#320): one hashtag and one link
# made to be rising, as the post above is. A server ranks neither by itself here — it runs no
# worker, and nothing on a new one was used by enough people — so a row is written for each,
# beside the uses a server would have counted: twelve people today and three yesterday for the
# hashtag, twenty today for the link. The link leads to a host this server has only heard of,
# and its title carries the marks a page's title may. Counted once, however often this runs.
rising_at = Time.now.utc
rising_tag = Tag.find_or_create_by_names(["FediqoRising"]).first
rising_tag.update!(trendable: true, usable: true, listable: true)
if rising_tag.history.get(rising_at).accounts.zero?
  (1..12).each { |i| rising_tag.history.add(1000 + i, rising_at) }
  (1..3).each { |i| rising_tag.history.add(2000 + i, rising_at - 1.day) }
end
tag_trend = TagTrend.find_or_initialize_by(tag_id: rising_tag.id)
tag_trend.assign_attributes(score: 9.0, rank: 1, allowed: true, language: "")
tag_trend.save!
rising_card = PreviewCard.find_or_initialize_by(url: "https://elsewhere.example/stories/rising")
rising_card.assign_attributes(
  title: "A story <b>rising</b> & more", description: "What the page says of itself.", type: :link,
  provider_name: "Elsewhere", provider_url: "https://elsewhere.example", author_name: "Somebody",
  author_url: "https://elsewhere.example/somebody", trendable: true, language: "en"
)
rising_card.save!
(1..20).each { |i| rising_card.history.add(3000 + i, rising_at) } if rising_card.history.get(rising_at).accounts.zero?
card_trend = PreviewCardTrend.find_or_initialize_by(preview_card_id: rising_card.id)
card_trend.assign_attributes(score: 7.0, rank: 1, allowed: true, language: "en")
card_trend.save!

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

# And this app as it would register itself for every part a sign-in may be asked for, for the
# checks of how a sign-in is widened through the server's own pages (#347) — made here for the
# same reason, so those checks register nothing. A token a run of them left live is revoked: a
# page is shown only where no token of the words asked for lives, and a check looks for the page.
widening = Doorkeeper::Application.find_or_create_by!(name: "fediqo-servers-signin-ask") do |record|
  record.redirect_uri = "fediqo://oauth"
  record.scopes = "#{sign_ins["dismissing"]["scopes"]} read:follows write:follows read:mutes write:mutes"
end
Doorkeeper::AccessToken.where(application: widening, revoked_at: nil).update_all(revoked_at: Time.now.utc)

# What the checks of what a Mastodon says of a person need (#310, #311): people who are each
# one thing a page has to say — somebody with a name, words and fields of their own, a locked
# account, one that hides who it follows, one that moved, one suspended, one limited, a bot
# with nothing at all, one who blocks the writer — and two who live on another server, which
# this one knows only part of. Idempotent, as the rest is.
#
# **Nobody is told of anything here, and nothing reaches a home or a list.** Follows and the
# one boost are made in the model, which tells nobody; a post's fan-out is left queued and never
# run (`tell` runs only the fan-outs it is handed); nobody is mentioned. One post is public and
# so stands in the public timeline, and so do the three that reached here from the one of
# another server, which carry the rising link (#379, below); the rest are unlisted, for
# followers or for nobody. None of
# these people follows the writer, so the checks of notices read what they read before.
wrote = lambda do |who, words, visibility = "unlisted", **more|
  Status.where(account: who, reblog_of_id: nil).where("text LIKE ?", "%#{words}%").first ||
    PostStatusService.new.call(who, text: words, visibility: visibility, **more)
end
follows = ->(who, whom) { who.follow!(whom) unless who.following?(whom) }

# A picture a name can be partly written in: the smallest PNG there is, one pixel. Said and
# gone on from where this server cannot make a picture of it — the checks then say so.
pixel = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
pictured = lambda do |shortcode, domain|
  CustomEmoji.find_by(shortcode: shortcode, domain: domain) || begin
    file = StringIO.new(pixel)
    file.define_singleton_method(:original_filename) { "#{shortcode}.png" }
    file.define_singleton_method(:content_type) { "image/png" }
    CustomEmoji.create!(shortcode: shortcode, domain: domain, image: file)
  rescue StandardError => e
    warn "seed: no picture for :#{shortcode}: — #{e.class}: #{e.message}"
    nil
  end
end
pictured.call("fediqo_mark", nil)
pictured.call("far_mark", "elsewhere.example")

# Somebody whole: a name partly written in a picture, words that name a hashtag, a person and a
# link, two fields — one of them checked — and posts of every reach.
shown = person.call("fediqo_person")
shown.display_name = "Per :fediqo_mark: Son"
shown.note = "Reads #fediqo309 beside @fediqo_other :fediqo_mark:\nhttps://example.com/about"
shown[:fields] = [
  { "name" => "Site", "value" => "https://example.com/per", "verified_at" => "2026-10-01T00:00:00.000Z" },
  { "name" => "Pronouns :fediqo_mark:", "value" => "they/them" }
]
shown.save! if shown.changed?
person_posts = (1..5).map { |n| wrote.call(shown, format("fediqo309seed post %02d", n)) }
person_public = wrote.call(shown, "fediqo309seed in public :fediqo_mark:", "public")
person_private = wrote.call(shown, "fediqo309seed for followers", "private")
person_direct = wrote.call(shown, "fediqo309seed for nobody", "direct")
person_answer = wrote.call(shown, "fediqo309seed answering", thread: person_posts.first)
# The boost is the row a boost is and no more: the service would queue a notice for its author.
person_boost = Status.where(account: shown, reblog_of_id: plain.id).first ||
  shown.statuses.create!(reblog: plain, text: "", visibility: "public")

# Who follows them and whom they follow. With the one who hides their lists and the two who
# live elsewhere, below, that is eight followers — four full stretches of two, and a fifth with
# nobody — and four they follow.
fans = (1..5).map { |n| person.call("fediqo_fan_#{n}") }
fans.each { |fan| follows.call(fan, shown) }
fans.first(3).each { |fan| follows.call(shown, fan) }
follows.call(shown, other)

# One who must agree to be followed, whom the writer has asked.
locked = person.call("fediqo_locked")
locked.update!(locked: true) unless locked.locked?
writer_account.request_follow!(locked) unless writer_account.requested?(locked) || writer_account.following?(locked)

# One who hides who they follow and who follows them — and has both.
hidden = person.call("fediqo_hidden")
hidden.update!(hide_collections: true) unless hidden.hide_collections
fans.first(2).each { |fan| follows.call(fan, hidden) }
follows.call(hidden, shown)
wrote.call(hidden, "fediqo309seed hidden")

# One who moved to the first; one this server suspended, who had a post and a follower; one it
# limited; an automated account with nothing; one who blocks the writer.
moved = person.call("fediqo_moved")
moved.update!(moved_to_account: shown) unless moved.moved_to_account_id == shown.id
gone = person.call("fediqo_gone")
unless gone.suspended?
  wrote.call(gone, "fediqo309seed gone")
  follows.call(fans.first, gone)
  gone.suspend!(block_email: false)
end
limited = person.call("fediqo_limited")
limited.silence! unless limited.silenced?
robot = person.call("fediqo_robot")
robot.update!(actor_type: "Service") unless robot.actor_type == "Service"
blocker = person.call("fediqo_blocker")
wrote.call(blocker, "fediqo309seed blocker")
follows.call(fans.first, blocker)
blocker.block!(writer_account) unless blocker.blocking?(writer_account)

# One the writer does not follow and nobody else does, for the check that follows and
# unfollows somebody (#313): no other check counts who follows them, and none lists them —
# named unlike the rest, so that no search for the seed's people finds one more.
followable = person.call("followable_313")

# One whose own account the checks change and put back (#312), and one who asks to follow it:
# nobody else asks after, counts or lists either. Limited by this server, so that being found
# turned on lists it in no directory another check reads; named unlike the rest, so that no
# search for the seed's people finds them. Put back here as the checks start it, every run,
# whatever a run that stopped part way left.
own = person.call("own_312")
own_fan = person.call("own_fan_312")
own.silence! unless own.silenced?
FollowRequest.where(target_account: own).destroy_all
Follow.where(target_account: own).destroy_all
own.update!(
  display_name: "Own 312", note: "Words of my own.", locked: false, discoverable: false, hide_collections: false,
  fields_attributes: [{ name: "site", value: "own.example" }, { name: "pronouns", value: "they" }]
)

# How the writer stands to people: they mute one and block another.
writer_account.mute!(fans[4]) unless writer_account.muting?(fans[4])
writer_account.block!(fans[3]) unless writer_account.blocking?(fans[3])

# **Two who live on another server**, as this one would hold them once it had heard of them: a
# name there, counts their own server said, and only the follows and the posts that reached
# here. Made in the model — nothing is asked of `elsewhere.example`, which does not exist. One
# says it hides its lists; the other says nothing either way.
afar = lambda do |username, **more|
  Account.find_by(username: username, domain: "elsewhere.example") || Account.create!(
    username: username, domain: "elsewhere.example", protocol: :activitypub, actor_type: "Person",
    uri: "https://elsewhere.example/users/#{username}", url: "https://elsewhere.example/@#{username}",
    inbox_url: "https://elsewhere.example/users/#{username}/inbox",
    shared_inbox_url: "https://elsewhere.example/inbox",
    outbox_url: "https://elsewhere.example/users/#{username}/outbox",
    followers_url: "https://elsewhere.example/users/#{username}/followers",
    **more
  )
end
heard = lambda do |who, n|
  uri = "#{who.uri}/statuses/#{n}"
  Status.find_by(uri: uri) || Status.create!(
    account: who, uri: uri, url: "https://elsewhere.example/@#{who.username}/#{n}",
    text: "<p>fediqo309seed far #{n}</p>", visibility: :unlisted, language: "en"
  )
end
counted = lambda do |who, followers, following, statuses|
  stat = who.account_stat
  stat.update!(followers_count: followers, following_count: following, statuses_count: statuses)
end
far = afar.call(
  "far", display_name: "Far :far_mark: Away", note: "<p>Lives elsewhere :far_mark:</p>",
  fields: [{ "name" => "Home", "value" => "<a href=\"https://elsewhere.example/far\">elsewhere.example/far</a>" }]
)
far_posts = (1..3).map { |n| heard.call(far, n) }
# What the checks of the posts sharing a rising link need (#379): the three that reached here
# from them carry the link the seed made rise, as this server would have found it in them, and
# stand public — a server lists a link's posts only where they are public, and only of somebody
# who chose to be found, as they do below. Theirs, and nobody new's: anybody else listed by the
# link would be listed in the directory the checks of it read, and posts of anybody else would
# be counted where theirs are.
far_posts.each do |post|
  post.update_columns(visibility: "public") unless post.public_visibility?
  PreviewCardsStatus.find_or_create_by!(status_id: post.id, preview_card_id: rising_card.id) do |row|
    row.url = rising_card.url
  end
end
fans.first(2).each { |fan| follows.call(fan, far) }
follows.call(far, shown)
counted.call(far, 2811, 310, 1204)
far_hidden = afar.call("far_hidden", display_name: "Far Hidden", hide_collections: true)
follows.call(fans.first, far_hidden)
follows.call(far_hidden, shown)
counted.call(far_hidden, 77, 55, 33)

# What the checks of a directory of people need (#315): people who chose to be listed. The one
# who is whole, their five followers and the first of another server are listed; one suspended
# and one limited chose to be too, and a server gives neither. Written in the row itself, as
# the rest here is: nobody is told, and somebody suspended or of another server is not saved
# the ordinary way.
[shown, far, gone, limited, *fans].each { |who| who.update_columns(discoverable: true) unless who.discoverable }

# What the checks of the people a server suggests need (#315): somebody to suggest. A server
# suggests whoever its staff named, and here nobody else — no worker ranks anybody — so the
# people listed above are named, each of whom chose to be found. The writer is then suggested
# five of them: not the two they block and mute, nor the one suspended, nor the one limited.
suggested = [shown, far, gone, limited, *fans].map(&:acct).join(", ")
Setting.bootstrap_timeline_accounts = suggested unless Setting.bootstrap_timeline_accounts == suggested

# What the checks of what somebody set here need (#321): one person who set all three things a
# new post starts from — the one who hides their lists, whom the checks already sign in as and
# who writes nothing more. The writer sets nothing, and is answered what a server gives then.
hidden_settings = { "default_privacy" => "unlisted", "default_language" => "zh-TW", "default_sensitive" => true }
unless hidden_settings.all? { |key, value| hidden.user.settings[key] == value }
  hidden.user.settings.update(hidden_settings)
  hidden.user.save!
end

# Sign-ins the checks of people ask as: the writer's as this app makes it for reading, with and
# without the word that says how they stand to somebody; and one of the person who hides their
# lists, who is shown them all the same.
standing = "#{reading} read:follows"
# And one of the writer's that lacks the word for reading their own account, which what they
# set here is refused to (#321).
# And one that reads and holds both words of follows and nothing else that acts: what following
# a hashtag and listing the followed ones must be enough for (#318).
following = "#{standing} write:follows"
people_sign_ins = {
  "standing" => [user, standing], "hidden" => [hidden.user, "read write"], "narrow" => [user, "read:statuses"],
  "following" => [user, following],
  "own" => [own.user, "read write"], "ownFan" => [own_fan.user, "read write"]
}.transform_values do |(owner, scopes)|
  held = Doorkeeper::AccessToken.find_by(application: grained, resource_owner_id: owner.id, scopes: scopes, revoked_at: nil) ||
    Doorkeeper::AccessToken.create!(application: grained, resource_owner_id: owner.id, scopes: scopes, expires_in: nil)
  { "token" => held.token, "scopes" => scopes }
end
named = ->(who) { { "id" => who.id.to_s, "acct" => who.acct } }

# What the checks of what rides the profile part need (#312, #315, #318, #321): one reader of
# their own, whose picture and header are changed and taken away, who dismisses a suggestion,
# features somebody they follow and a hashtag, and dismisses and reacts to what the server
# announces — and nobody another check reads, counts or lists. Named unlike the rest. **Put
# back here as the checks start it, every run**, whatever a run that stopped part way left:
# no picture, no header, nobody dismissed, nobody and no hashtag featured, the one followed
# followed and the other not, no announcement dismissed and no reaction of the reader's.
parts = person.call("parts_321")
parts_followed = person.call("parts_followed_315")
parts_stranger = person.call("parts_stranger_315")
follows.call(parts, parts_followed)
parts.unfollow!(parts_stranger) if parts.following?(parts_stranger)
AccountPin.where(account: parts).destroy_all
FeaturedTag.where(account: parts).destroy_all
FollowRecommendationMute.where(account: parts).destroy_all
if parts.avatar.present? || parts.header.present?
  parts.avatar = nil
  parts.header = nil
  parts.save!
end
# Two announcements, published: one to dismiss and one to react to, with the other person's
# reaction already on it. Seen by every reader of this server.
announced = %w(dismiss react).to_h do |what|
  [what, Announcement.find_by(text: "fediqo321seed #{what}") ||
    Announcement.create!(text: "fediqo321seed #{what}", published: true, published_at: Time.now.utc)]
end
AnnouncementMute.where(account: parts).destroy_all
AnnouncementReaction.where(account: parts).destroy_all
AnnouncementReaction.find_or_create_by!(account: other, announcement: announced["react"], name: "👍")
# This app's words for every part, and the same without the profile part.
every_part = "#{acting} read:notifications write:notifications read:follows write:follows write:accounts"
parts_sign_ins = { "parts" => every_part, "partsLacking" => every_part.sub(" write:accounts", "") }
  .transform_values do |scopes|
    held = Doorkeeper::AccessToken.find_by(application: grained, resource_owner_id: parts.user.id, scopes: scopes, revoked_at: nil) ||
      Doorkeeper::AccessToken.create!(application: grained, resource_owner_id: parts.user.id, scopes: scopes, expires_in: nil)
    { "token" => held.token, "scopes" => scopes }
  end

# What the checks of tending the server need (#380, #381): somebody whose role is Admin and
# somebody whose role is Moderator, each with a password a check signs in with and a sign-in
# holding every word of every part this app asks for, tending's two among them; the writer —
# whose role is nobody's — holding tending's words too, since the words may be granted to
# anyone and only the role lets anything be done; this app as it registers itself now, for the
# check that signs in through the server's own page; and two open reports by the other person,
# one naming a post and a rule, one naming a post of somebody of another server. An app of
# their own for the tokens, whose words hold tending's. **Put back every run**: whatever a run
# did to the reports — taken on, closed — is undone, and the page's tokens left live revoked.
staffed = lambda do |username, email, password, role|
  found = Account.find_local(username)
  unless found
    made = User.new(email: email, password: password, password_confirmation: password, confirmed_at: Time.now.utc, approved: true)
    made.account = Account.new(username: username)
    made.skip_confirmation_notification! if made.respond_to?(:skip_confirmation_notification!)
    made.save!(validate: false)
    found = made.account
  end
  found.user.approve! if found.user.respond_to?(:approve!) && !found.user.approved?
  found.user.update_columns(role_id: UserRole.find_by!(name: role).id) unless found.user.role_id == UserRole.find_by!(name: role).id
  found
end
admin = staffed.call("fediqo_admin", "admin@example.com", "LocalOnlyPass3", "Admin")
mod = staffed.call("fediqo_mod", "mod@example.com", "LocalOnlyPass4", "Moderator")
everything = "#{every_part} write:media read:bookmarks read:favourites read:mutes write:mutes read:blocks write:blocks " \
  "write:reports admin:read admin:write"
tending_app = Doorkeeper::Application.find_or_create_by!(name: "fediqo-servers-tending") do |record|
  record.redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
  record.scopes = "read write admin:read admin:write"
end
tending_sign_ins = { "admin" => [admin, everything], "mod" => [mod, everything], "writer" => [writer_account, "#{reading} admin:read admin:write"] }
  .transform_values do |(who, scopes)|
    # Tending's tokens do not outlive the checks by long: two days, and a fresh one once lapsed.
    held = Doorkeeper::AccessToken.where(application: tending_app, resource_owner_id: who.user.id, scopes: scopes, revoked_at: nil)
      .detect { |token| !token.expired? } ||
      Doorkeeper::AccessToken.create!(application: tending_app, resource_owner_id: who.user.id, scopes: scopes, expires_in: 2.days.to_i)
    named.call(who).merge("token" => held.token, "scopes" => scopes)
  end
tending_ask = Doorkeeper::Application.find_or_create_by!(name: "fediqo-servers-tending-ask") do |record|
  record.redirect_uri = "fediqo://oauth"
  record.scopes = everything
end
Doorkeeper::AccessToken.where(application: tending_ask, revoked_at: nil).update_all(revoked_at: Time.now.utc)
rule = Rule.find_by(text: "fediqo381seed rule") || Rule.create!(text: "fediqo381seed rule", priority: 0)
reported = [
  ["fediqo381seed one", shown, person_public, :violation, [rule.id]],
  ["fediqo381seed two", far, far_posts.first, :spam, []],
].map do |(words, whom, post, category, rules)|
  report = Report.find_by(account: other, comment: words) ||
    Report.create!(account: other, target_account: whom, status_ids: [post.id], comment: words, category: category, rule_ids: rules)
  report.update_columns(action_taken_at: nil, action_taken_by_account_id: nil, assigned_account_id: nil)
  report
end

# What the checks of the server's accounts need (#382): sign-ups that wait to be let in — the
# server asks for approval — each with what they wrote; one a check lets in and one it turns
# away, which the server deletes; and somebody a check warns, limits, marks sensitive, freezes
# and suspends, and takes each back from. Nobody another check reads, and none named as the
# seed's people are. **Put back every run**: whoever was let in waits again, whoever was turned
# away is made again, and the one acted on is held in nothing.
Setting.registrations_mode = "approved" unless Setting.registrations_mode == "approved"
asking_to_join = lambda do |username, words|
  found = Account.find_local(username)
  unless found
    secret = SecureRandom.hex(16)
    made = User.new(
      email: "#{username}@example.com", password: secret, password_confirmation: secret, confirmed_at: Time.now.utc,
      approved: false
    )
    made.account = Account.new(username: username)
    made.skip_confirmation_notification! if made.respond_to?(:skip_confirmation_notification!)
    made.save!(validate: false)
    found = made.account
  end
  found.user.update_columns(approved: false) if found.user.approved?
  request = UserInviteRequest.find_or_initialize_by(user: found.user)
  request.update!(text: words) unless request.persisted? && request.text == words
  found
end
waiting_ones = {
  "stays" => asking_to_join.call("asks_382", "I read the rules and would like to write here."),
  "letIn" => asking_to_join.call("asks_382_in", "Let me in, please."),
  "turnedAway" => asking_to_join.call("asks_382_away", "Buy cheap watches."),
}
acted_on = person.call("acted_382")
acted_on.unsuspend! if acted_on.suspended?
acted_on.unsilence! if acted_on.silenced?
acted_on.unsensitize! if acted_on.sensitized?
acted_on.user.enable! if acted_on.user.disabled?

# What the checks of the servers and addresses this one refuses need (#383): a server suspended
# and one limited, with what is refused of each and why; one allowed; a mail domain refused;
# and a range of addresses refused to sign up from. Hosts nobody reaches, and the addresses of
# the documentation range. **Put back every run**: each made again where a check took it off,
# and as it was where a check changed it; what a check made and left is taken off.
DomainBlock.where(domain: %w(fediqo383.example)).destroy_all
DomainAllow.where(domain: %w(fediqo383.example)).destroy_all
EmailDomainBlock.where(domain: %w(fediqo383.example)).destroy_all
IpBlock.where(ip: "198.51.100.0/24").destroy_all
blocked = {
  "suspended" => ["suspended.example", { severity: :suspend, reject_media: false, reject_reports: false,
                                         private_comment: "fediqo383seed spam", public_comment: "Spam", obfuscate: false }],
  "limited" => ["limited.example", { severity: :silence, reject_media: true, reject_reports: false,
                                     private_comment: "", public_comment: "Too loud", obfuscate: false }],
}.transform_values do |(domain, said)|
  block = DomainBlock.find_or_initialize_by(domain: domain)
  block.assign_attributes(said)
  block.save!
  block
end
allowed = DomainAllow.find_or_create_by!(domain: "allowed.example")
refused_mail = EmailDomainBlock.find_or_create_by!(domain: "spam.example")
refused_ip = IpBlock.find_or_initialize_by(ip: "192.0.2.0/24")
refused_ip.assign_attributes(severity: :sign_up_block, comment: "fediqo383seed range", expires_at: nil)
refused_ip.save!

more = "/tmp/fediqo-mastodon-tokens.json"
owner_only.call(more, JSON.generate(tokens.merge(
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
  ),
  "signIn" => { "id" => widening.uid, "secret" => widening.secret, "scopes" => widening.scopes.to_s },
  "tending" => tending_sign_ins.merge(
    "adminPassword" => "LocalOnlyPass3", "adminEmail" => "admin@example.com",
    "app" => { "id" => tending_ask.uid, "secret" => tending_ask.secret, "scopes" => tending_ask.scopes.to_s },
    "reports" => reported.map { |report| report.id.to_s },
    "waiting" => waiting_ones.transform_values { |who| named.call(who) },
    "actedOn" => named.call(acted_on),
    "servers" => {
      "suspended" => blocked["suspended"].id.to_s, "limited" => blocked["limited"].id.to_s,
      "allowed" => allowed.id.to_s, "mail" => refused_mail.id.to_s, "ip" => refused_ip.id.to_s,
    }
  ),
  "people" => people_sign_ins.merge(
    "person" => named.call(shown), "locked" => named.call(locked), "hidden" => named.call(hidden).merge(people_sign_ins["hidden"]),
    "moved" => named.call(moved), "gone" => named.call(gone), "limited" => named.call(limited),
    "robot" => named.call(robot), "blocker" => named.call(blocker), "followable" => named.call(followable),
    "own" => named.call(own).merge(people_sign_ins["own"]), "ownFan" => named.call(own_fan).merge(people_sign_ins["ownFan"]),
    "muted" => named.call(fans[4]), "blocked" => named.call(fans[3]),
    "far" => named.call(far), "farHidden" => named.call(far_hidden),
    "fans" => fans.map { |fan| named.call(fan) },
    "posts" => (person_posts + [person_public, person_answer, person_boost]).map { |post| post.id.to_s },
    "kept" => { "private" => person_private.id.to_s, "direct" => person_direct.id.to_s },
    "farPosts" => far_posts.map { |post| post.id.to_s }
  ),
  "parts" => named.call(parts).merge(
    "token" => parts_sign_ins["parts"]["token"], "scopes" => every_part,
    "lacking" => parts_sign_ins["partsLacking"]["token"], "lackingScopes" => parts_sign_ins["partsLacking"]["scopes"],
    "followed" => named.call(parts_followed), "stranger" => named.call(parts_stranger),
    "dismiss" => announced["dismiss"].id.to_s, "react" => announced["react"].id.to_s
  )
)))
puts "wrote #{more}"
