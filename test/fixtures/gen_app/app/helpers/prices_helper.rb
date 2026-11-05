module PricesHelper
  def price(value, unit: "USD", precision: 2)
    "#{Cybertrain::Cast.float(value).round(Cybertrain::Cast.int(precision))} #{unit}"
  end

  def post_badge(post, kind = "info", &block)
    link_to_path("#{kind}: #{block_given? ? yield : "-"}", post_path(post), class: "badge")
  end
end
