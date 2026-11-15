def round_scale(v, scale)
  f = case v
      when Float then v
      when String then v.to_f
      else 0.0
      end
  f.round(scale).to_f
end
x = "1.005".to_f
puts x.round(2)
puts round_scale(x, 2)
puts round_scale("0.285", 2)
