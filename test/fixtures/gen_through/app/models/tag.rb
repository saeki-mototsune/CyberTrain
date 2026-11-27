class Tag
  has_many :posts, through: :taggings
end
