class Post
  has_many :comments, as: :commentable, dependent: :destroy
  has_one :note, as: :notable, dependent: :nullify

  def caption = "post " + title
end
