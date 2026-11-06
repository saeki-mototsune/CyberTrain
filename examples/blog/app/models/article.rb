# Columns, associations and the Cybertrain::Model superclass come from
# gen/models/article.rb, generated from db/schema.rb (and the has_many
# line below) by `spin run gen`.
class Article
  validates :title, presence: true
  validates :body, presence: true, length: { minimum: 10 }

  # Article#comments, the comments' Relation. destroy deletes them first
  # (one DELETE, in destroy's transaction): the foreign key would refuse
  # to delete an article that still has comments.
  has_many :comments, dependent: :delete_all
end
