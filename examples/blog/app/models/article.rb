# Columns, associations and the Cybertrain::Model superclass come from
# gen/models/article.rb, generated from db/schema.rb (and the lines below)
# by `spin run gen`.
class Article
  validates :title, presence: true
  validates :title, uniqueness: true
  validates :body, presence: true, length: { minimum: 10 }

  # Article#comments, the comments' Relation. destroy destroys them first
  # (each comment's own destroy, callbacks included, in destroy's
  # transaction): the foreign key would refuse to delete an article that
  # still has comments.
  has_many :comments, dependent: :destroy

  # Article.recent: newest first (the index's order).
  scope :recent, -> { order(created_at: :desc) }
end
