class Photo
  has_many :comments, as: :commentable
  has_many :notes, as: :notable, dependent: :delete_all

  def caption = "photo " + url
end
