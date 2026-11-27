class Post
  belongs_to :author, optional: true
  has_many :taggings, dependent: :destroy
  has_many :tags, through: :taggings
  has_many :labels, through: :taggings, source: :tag
  has_many :co_posts, through: :author, source: :posts
end
