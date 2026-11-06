class Post
  validates :title, presence: true
  has_many :comments, dependent: :destroy
  scope :recent, -> { order(created_at: :desc) }
  scope :min_views, ->(n) { where("views >= ?", n) }

  def summary = title[0, 3]
end
