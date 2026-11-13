# A helper shared by every test file: test/support/ is bundled once.
def slug_of(title)
  title.downcase.tr(" ", "-")
end
