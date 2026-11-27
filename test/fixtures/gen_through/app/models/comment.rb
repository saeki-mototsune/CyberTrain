class Comment
  belongs_to :post
  has_many :thread_comments, through: :post, source: :comments
  has_many :writers, through: :post, source: :author
end
