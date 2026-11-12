class Article < ApplicationRecord
  has_many :comments, dependent: :delete_all

  validates :title, presence: true
  validates :body, presence: true, length: { minimum: 10 }

  # The article's picture, as examples/blog has it: Active Storage in place of
  # the columns and methods `cybertrain generate attachment` writes. The same
  # limits apply: four image types, 2 MB, and the type is read from the
  # file's bytes, never taken from the browser.
  COVER_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"].freeze
  COVER_MAX_BYTES = 2.megabytes

  has_one_attached :cover
  validate :cover_is_a_small_image

  private

  def cover_is_a_small_image
    return unless cover.attached?

    errors.add(:cover, "is too large (maximum is 2 MB)") if cover.blob.byte_size > COVER_MAX_BYTES
    errors.add(:cover, "must be a PNG, JPEG, GIF or WebP image") unless COVER_TYPES.include?(cover_type_from_bytes)
  end

  # Active Storage's own content type falls back to the name and the type the
  # browser declared when the bytes say nothing, so a script named cover.png
  # would pass as image/png. For a file being attached, ask Marcel about the
  # bytes alone; one already stored was checked when it was attached.
  def cover_type_from_bytes
    change = attachment_changes["cover"]
    upload = change.nil? ? nil : change.attachable
    return cover.blob.content_type unless upload.respond_to?(:tempfile)

    type = Marcel::MimeType.for(upload.tempfile)
    upload.tempfile.rewind
    type
  end
end
