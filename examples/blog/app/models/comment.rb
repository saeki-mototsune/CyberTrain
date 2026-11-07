# Columns and the Cybertrain::Model superclass come from
# gen/models/comment.rb, generated from db/schema.rb (and the belongs_to
# line below) by `spin run gen`.
class Comment
  validates :commenter, presence: true
  validates :body, presence: true

  # Comment#article, through the article_id foreign key.
  belongs_to :article
end
