# Columns, associations and the Cybertrain::Model superclass come from
# gen/models/article.rb, generated from db/schema.rb (and the lines below)
# by `spin run gen`.
class Article
  # cybertrain:attachment cover -- written by `cybertrain generate attachment`; yours to change.
  # The bytes live in storage/uploads (Cybertrain::BlobStore), never in the
  # database: the five cover_* columns hold their key and metadata. The type
  # stored is the one the server detected from the bytes, never the client's.
  # COVER_MAX_BYTES must stay at or below config.max_upload_bytes (5 MiB), or a
  # larger file is a 400 from the parser instead of the 422 below.
  COVER_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"]
  COVER_MAX_BYTES = 2_097_152

  before_validation { |article| article.validate_cover_upload }
  before_save { |article| article.store_cover_upload }
  after_save { |article| article.delete_replaced_cover }
  after_destroy { |article| article.purge_cover }

  # Takes the Cybertrain::UploadedFile of a form (params.nested(:article).upload(:cover)),
  # or nil. Nil or an empty file keeps the current one.
  def cover_file=(upload)
    @cover_upload = upload.nil? ? Cybertrain::UploadedFile.blank : upload
  end

  def cover_attached?
    !cover_key.to_s.empty?
  end

  # Where the file is served from (the download action of the
  # controller); "" when none is attached. ?v= changes with the content,
  # so a replaced file is not served from a browser's cache.
  def cover_url
    cover_attached? ? "/articles/#{id}/cover?v=#{cover_checksum.to_s[0, 12]}" : ""
  end

  # Public so the callbacks above (which receive the record) can call them.

  def validate_cover_upload
    pending = cover_pending_upload
    return nil if pending.empty?

    # The messages are the blog's dictionary's
    # (activerecord.errors.models.article.attributes.cover.*, config/locales).
    errors.add(:cover, I18n.error_message("article", :cover, :too_large)) if pending.byte_size > COVER_MAX_BYTES
    errors.add(:cover, I18n.error_message("article", :cover, :content_type)) unless COVER_TYPES.empty? || COVER_TYPES.include?(pending.detected_content_type)
    nil
  end

  # Writes the new file to disk under a random key and points the columns
  # at it. The old key is kept for delete_replaced_cover. A save that fails
  # after this point (a database error) leaves the new blob orphaned.
  def store_cover_upload
    pending = cover_pending_upload
    return nil if pending.empty?

    key = Cybertrain::BlobStore.new_key
    Cybertrain::BlobStore.write(key, pending.body_bytes)
    @replaced_cover_key = cover_key.to_s
    self.cover_key = key
    self.cover_filename = pending.original_filename
    self.cover_content_type = pending.detected_content_type
    self.cover_byte_size = pending.byte_size
    self.cover_checksum = pending.sha256_hex
    @cover_upload = Cybertrain::UploadedFile.blank
    nil
  end

  def delete_replaced_cover
    old = @replaced_cover_key
    old = "" if old.nil?
    Cybertrain::BlobStore.delete(old) unless old.empty?
    @replaced_cover_key = ""
    nil
  end

  def purge_cover
    Cybertrain::BlobStore.delete(cover_key.to_s)
    nil
  end

  def cover_pending_upload
    upload = @cover_upload
    upload.nil? ? Cybertrain::UploadedFile.blank : upload
  end

  validates :title, presence: true
  validates :title, uniqueness: true
  validates :body, presence: true, length: { minimum: 10 }

  # Article#comments, the comments' Relation. destroy destroys them first
  # (each comment's own destroy, callbacks included, in destroy's
  # transaction): the foreign key would refuse to delete an article that
  # still has comments.
  has_many :comments, dependent: :destroy

  # Article.recent: newest first (the index's order).
  scope :recent, -> { order(created_at: :desc) }

  # What /articles.json and /articles/1.json show: the columns without the
  # five cover_* ones (the storage key and its metadata stay inside), and
  # where the cover is served from ("" when there is none).
  def public_json
    out = {}
    as_json.each do |name, value|
      out[name] = value unless name.start_with?("cover_")
    end
    out["cover_url"] = cover_url
    out
  end
end
