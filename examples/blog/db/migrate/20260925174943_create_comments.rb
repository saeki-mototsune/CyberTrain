class CreateComments < Cybertrain::Migration::Base
  def change
    create_table "comments" do |t|
      t.string "commenter"
      t.text "body"
      t.references :article
      t.timestamps
    end
  end
end
