class Note
  belongs_to :notable, polymorphic: true, optional: true
end
