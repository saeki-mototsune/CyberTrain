# Columns, associations (Article#comments, from the comments.article_id
# foreign key) and the Cybertrain::Model superclass come from
# gen/models/article.rb, generated from db/schema.rb by `spin run gen`.
class Article
  validates :title, presence: true
  validates :body, presence: true, length: { minimum: 10 }

  # Rails' `has_many :comments, dependent: :destroy`: the foreign key
  # would refuse to delete an article that still has comments.
  before_destroy { |article| Comment.where(article_id: article.id).delete_all }
end
