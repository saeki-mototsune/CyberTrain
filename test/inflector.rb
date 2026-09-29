require "cybertrain/test"
require "cybertrain/generator/inflector"

# Cybertrain::Inflector is a port of ActiveSupport::Inflector with Rails'
# default English inflections. The tables below are Rails' own test data
# (activesupport/test/inflector_test_cases.rb, 8.1.4), and each test mirrors
# an assertion loop of activesupport/test/inflector_test.rb.

SINGULAR_TO_PLURAL = {
  "search"      => "searches",
  "switch"      => "switches",
  "fix"         => "fixes",
  "box"         => "boxes",
  "process"     => "processes",
  "address"     => "addresses",
  "case"        => "cases",
  "stack"       => "stacks",
  "wish"        => "wishes",
  "fish"        => "fish",
  "jeans"       => "jeans",
  "funky jeans" => "funky jeans",
  "my money"    => "my money",

  "category"    => "categories",
  "query"       => "queries",
  "ability"     => "abilities",
  "agency"      => "agencies",
  "movie"       => "movies",

  "archive"     => "archives",

  "index"       => "indices",

  "wife"        => "wives",
  "safe"        => "saves",
  "half"        => "halves",

  "move"        => "moves",

  "salesperson" => "salespeople",
  "person"      => "people",

  "spokesman"   => "spokesmen",
  "man"         => "men",
  "woman"       => "women",

  "basis"       => "bases",
  "diagnosis"   => "diagnoses",
  "diagnosis_a" => "diagnosis_as",

  "datum"       => "data",
  "medium"      => "media",
  "stadium"     => "stadia",
  "analysis"    => "analyses",
  "my_analysis" => "my_analyses",

  "node_child"  => "node_children",
  "child"       => "children",

  "experience"  => "experiences",
  "day"         => "days",

  "comment"     => "comments",
  "foobar"      => "foobars",
  "newsletter"  => "newsletters",

  "old_news"    => "old_news",
  "news"        => "news",

  "series"      => "series",
  "miniseries"  => "miniseries",
  "species"     => "species",

  "quiz"        => "quizzes",

  "perspective" => "perspectives",

  "ox"          => "oxen",
  "photo"       => "photos",
  "buffalo"     => "buffaloes",
  "tomato"      => "tomatoes",
  "dwarf"       => "dwarves",
  "elf"         => "elves",
  "information" => "information",
  "equipment"   => "equipment",
  "bus"         => "buses",
  "status"      => "statuses",
  "status_code" => "status_codes",
  "mouse"       => "mice",

  "louse"       => "lice",
  "house"       => "houses",
  "octopus"     => "octopi",
  "virus"       => "viri",
  "alias"       => "aliases",
  "portfolio"   => "portfolios",

  "vertex"      => "vertices",
  "matrix"      => "matrices",
  "matrix_fu"   => "matrix_fus",

  "axis"        => "axes",
  "taxi"        => "taxis", # prevents regression
  "testis"      => "testes",
  "crisis"      => "crises",

  "rice"        => "rice",
  "shoe"        => "shoes",

  "horse"       => "horses",
  "prize"       => "prizes",
  "edge"        => "edges",

  "database"    => "databases",

  # regression tests against improper inflection regexes
  "|ice"        => "|ices",
  "|ouse"       => "|ouses",
  "slice"       => "slices",
  "police"      => "police"
}

# Rails' Irregularities minus cow/kine and genus/genera, which its test
# registers itself with inflect.irregular (app-defined inflections are not
# supported here).
IRREGULARITIES = {
  "person" => "people",
  "man"    => "men",
  "child"  => "children",
  "sex"    => "sexes",
  "move"   => "moves",
  "zombie" => "zombies"
}

UNCOUNTABLES = %w[equipment information rice money species series fish sheep jeans police]

CAMEL_TO_UNDERSCORE = {
  "Product"               => "product",
  "SpecialGuest"          => "special_guest",
  "ApplicationController" => "application_controller",
  "Area51Controller"      => "area51_controller",
  "AppCDir"               => "app_c_dir",
  "Accountsv2N2Test"      => "accountsv2_n2_test"
}

CAMEL_TO_UNDERSCORE_WITHOUT_REVERSE = {
  "HTMLTidy"           => "html_tidy",
  "HTMLTidyGenerator"  => "html_tidy_generator",
  "FreeBSD"            => "free_bsd",
  "HTML"               => "html",
  "ForceXMLController" => "force_xml_controller"
}

CAMEL_WITH_MODULE_TO_UNDERSCORE_WITH_SLASH = {
  "Admin::Product"                     => "admin/product",
  "Users::Commission::Department"      => "users/commission/department",
  "UsersSection::CommissionDepartment" => "users_section/commission_department"
}

test "pluralize turns every Rails singular into its plural, keeping a capital" do
  SINGULAR_TO_PLURAL.each do |singular, plural|
    assert_equal plural, Cybertrain::Inflector.pluralize(singular)
    assert_equal plural.capitalize, Cybertrain::Inflector.pluralize(singular.capitalize)
  end
end

test "singularize turns every Rails plural into its singular, keeping a capital" do
  SINGULAR_TO_PLURAL.each do |singular, plural|
    assert_equal singular, Cybertrain::Inflector.singularize(plural)
    assert_equal singular.capitalize, Cybertrain::Inflector.singularize(plural.capitalize)
  end
end

test "pluralize leaves a plural alone and singularize a singular" do
  SINGULAR_TO_PLURAL.each do |singular, plural|
    assert_equal plural, Cybertrain::Inflector.pluralize(plural)
    assert_equal plural.capitalize, Cybertrain::Inflector.pluralize(plural.capitalize)
    assert_equal singular, Cybertrain::Inflector.singularize(singular)
    assert_equal singular.capitalize, Cybertrain::Inflector.singularize(singular.capitalize)
  end
end

test "irregulars inflect both ways, are idempotent and keep the first letter's case" do
  IRREGULARITIES.each do |singular, plural|
    assert_equal plural, Cybertrain::Inflector.pluralize(singular)
    assert_equal singular, Cybertrain::Inflector.singularize(plural)
    assert_equal plural, Cybertrain::Inflector.pluralize(plural)
    assert_equal singular, Cybertrain::Inflector.singularize(singular)
    assert_equal plural.capitalize, Cybertrain::Inflector.pluralize(singular.capitalize)
    assert_equal singular.capitalize, Cybertrain::Inflector.singularize(plural.capitalize)
  end
  assert_equal "salespeople", Cybertrain::Inflector.pluralize("salesperson")
  assert_equal "spokesmen", Cybertrain::Inflector.pluralize("spokesman")
  assert_equal "women", Cybertrain::Inflector.pluralize("woman")
  assert_equal "mice", Cybertrain::Inflector.pluralize("mouse")
  assert_equal "mouse", Cybertrain::Inflector.singularize("mice")
  # Not a default irregular: Rails' test adds cow/kine itself.
  assert_equal "cows", Cybertrain::Inflector.pluralize("cow")
end

test "uncountables stay put, also at the end of a phrase but not after an underscore" do
  UNCOUNTABLES.each do |word|
    assert_equal word, Cybertrain::Inflector.pluralize(word)
    assert_equal word, Cybertrain::Inflector.singularize(word)
    assert_equal word.capitalize, Cybertrain::Inflector.pluralize(word.capitalize)
    assert_equal word.upcase, Cybertrain::Inflector.singularize(word.upcase)
  end
  assert_equal "my money", Cybertrain::Inflector.pluralize("my money")
  assert_equal "funky jeans", Cybertrain::Inflector.singularize("funky jeans")
  # "_" is a word character, so /\bfish\Z/ does not match "blog_fish".
  assert_equal "blog_fishes", Cybertrain::Inflector.pluralize("blog_fish")
  assert_equal "news", Cybertrain::Inflector.pluralize("news")
  assert_equal "news", Cybertrain::Inflector.singularize("news")
end

test "the empty string stays empty" do
  assert_equal "", Cybertrain::Inflector.pluralize("")
  assert_equal "", Cybertrain::Inflector.singularize("")
end

test "compound names inflect their last word" do
  assert_equal "blog_posts", Cybertrain::Inflector.pluralize("blog_post")
  assert_equal "blog_post", Cybertrain::Inflector.singularize("blog_posts")
  assert_equal "sales_people", Cybertrain::Inflector.pluralize("sales_person")
  assert_equal "sales_person", Cybertrain::Inflector.singularize("sales_people")
  assert_equal "line_items", Cybertrain::Inflector.pluralize("line_item")
  assert_equal "status_codes", Cybertrain::Inflector.pluralize("status_code")
  assert_equal "node_child", Cybertrain::Inflector.singularize("node_children")
  assert_equal "Blog_posts", Cybertrain::Inflector.pluralize("Blog_post")
  # Rails' ClassNameToTableName (tableize = pluralize(underscore(name))).
  assert_equal "primary_spokesmen", Cybertrain::Inflector.pluralize(Cybertrain::Inflector.underscore("PrimarySpokesman"))
  assert_equal "node_children", Cybertrain::Inflector.pluralize(Cybertrain::Inflector.underscore("NodeChild"))
  assert_equal "calculus", Cybertrain::Inflector.pluralize(Cybertrain::Inflector.underscore("Calculu"))
end

test "underscore matches Rails" do
  CAMEL_TO_UNDERSCORE.each { |camel, under| assert_equal under, Cybertrain::Inflector.underscore(camel) }
  CAMEL_TO_UNDERSCORE_WITHOUT_REVERSE.each { |camel, under| assert_equal under, Cybertrain::Inflector.underscore(camel) }
  CAMEL_WITH_MODULE_TO_UNDERSCORE_WITH_SLASH.each { |camel, under| assert_equal under, Cybertrain::Inflector.underscore(camel) }
  assert_equal "html_parser", Cybertrain::Inflector.underscore("HTMLParser")
  assert_equal "admin/posts_controller", Cybertrain::Inflector.underscore("Admin::PostsController")
  assert_equal "abc1", Cybertrain::Inflector.underscore("ABC1")
  assert_equal "foo_bar", Cybertrain::Inflector.underscore("Foo-Bar")
  assert_equal "foo_bar", Cybertrain::Inflector.underscore("foo-bar")
  assert_equal "posts_controller", Cybertrain::Inflector.underscore("posts_controller")
end

test "camelize matches Rails" do
  CAMEL_TO_UNDERSCORE.each { |camel, under| assert_equal camel, Cybertrain::Inflector.camelize(under) }
  CAMEL_WITH_MODULE_TO_UNDERSCORE_WITH_SLASH.each { |camel, under| assert_equal camel, Cybertrain::Inflector.camelize(under) }
  assert_equal "Admin::Users", Cybertrain::Inflector.camelize("admin/users")
  assert_equal "PostsController", Cybertrain::Inflector.camelize("posts_controller")
  assert_equal "CreatePosts", Cybertrain::Inflector.camelize("create_posts")
  assert_equal "Post", Cybertrain::Inflector.camelize("post")
  # The word after "_" or "/" is capitalized, the rest of it downcased.
  assert_equal "FooBar", Cybertrain::Inflector.camelize("foo_BAR")
  assert_equal "Admin::Useraccounts", Cybertrain::Inflector.camelize("admin/userAccounts")
  assert_equal "FOOBar", Cybertrain::Inflector.camelize("FOO_bar")
  assert_equal "Foo-bar", Cybertrain::Inflector.camelize("foo-bar")
  assert_equal "", Cybertrain::Inflector.camelize("")
end

Cybertrain::Test.run!
