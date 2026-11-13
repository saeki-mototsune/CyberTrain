class Article
  belongs_to :author, class_name: "User"
  validates :title, presence: true
end
