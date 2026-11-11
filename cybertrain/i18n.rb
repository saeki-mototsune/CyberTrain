# I18n, a top-level module as in Rails (plan decision D1). For now only
# the hook gen/locales.rb calls on load: Task 4 of the phase 4b plan
# replaces this stub with the dictionary lookup (t, l, locale, ...).
module I18n
  # Installs the application's dictionary: `texts` answers a String or nil
  # for a key ("ja.posts.index.title"), `lists` an Array<String> (empty
  # when absent). Passed positionally (spikes/NOTES.md rule 42).
  def self.install_dictionary(texts, lists) = nil
end
