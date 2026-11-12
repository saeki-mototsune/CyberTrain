class User
  validates :name, presence: true
  has_many :articles, foreign_key: :author_id
end
