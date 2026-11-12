class AddCoverToArticles < Cybertrain::Migration::Base
  def change
    add_column "articles", "cover_key", :string, null: false, default: "''"
    add_column "articles", "cover_filename", :string, null: false, default: "''"
    add_column "articles", "cover_content_type", :string, null: false, default: "''"
    add_column "articles", "cover_byte_size", :integer, null: false, default: "0"
    add_column "articles", "cover_checksum", :string, null: false, default: "''"
  end
end
