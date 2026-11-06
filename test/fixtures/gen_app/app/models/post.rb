class Post
  encrypts :secret_note
  validates :title, presence: true
  validates :title, uniqueness: true, length: { maximum: 40 }
  validates :views, numericality: { greater_than_or_equal_to: 0 }
  validate :title_not_reserved, if: :published?
  has_many :comments, dependent: :destroy
  scope :recent, -> { order(created_at: :desc) }
  scope :min_views, ->(n) { where("views >= ?", n) }

  def summary = title[0, 3]
  def published? = !published_on.nil?

  private

  def title_not_reserved
    errors.add(:title, "is reserved once published") if title.downcase == "admin"
  end
end
