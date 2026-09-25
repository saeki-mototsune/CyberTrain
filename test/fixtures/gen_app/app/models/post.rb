class Post
  validates :title, presence: true

  def summary = title[0, 3]
end
