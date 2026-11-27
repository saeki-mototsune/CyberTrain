class Comment
  belongs_to :article
  belongs_to :author, optional: true
  has_many :likes
end
