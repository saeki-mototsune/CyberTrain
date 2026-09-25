# Columns, associations (Comment#article, from the article_id foreign key)
# and the Cybertrain::Model superclass come from gen/models/comment.rb,
# generated from db/schema.rb by `spin run gen`.
class Comment
  validates :commenter, presence: true
  validates :body, presence: true
end
