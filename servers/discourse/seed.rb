# One public topic so a join has something to read. Skipped once any topic exists.
if Topic.where(deleted_at: nil).where.not(id: -1).none?
  user = User.find_by(username: "admin") || User.find(-1)
  category = Category.find_by(id: SiteSetting.uncategorized_category_id) || Category.first
  PostCreator.create!(
    user,
    title: "A topic on this machine",
    raw: "A public topic on this machine.",
    category: category&.id,
    skip_validations: true
  )
end
