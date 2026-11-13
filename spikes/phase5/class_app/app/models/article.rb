class Article
  belongs_to :user
  validates :title, presence: true
end
