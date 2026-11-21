require "cybertrain/http/query"
require "cybertrain/http/multipart"
require "cybertrain/http/client_error"
require "cybertrain/context"
require "cybertrain/test"

# Params is split in two: its structure lives in the HTTP layer
# (cybertrain/http/params.rb, filled by Query and Multipart) and the strong
# parameters (require, permit, expect, ParameterMissing) are added by
# reopening the class in cybertrain/params.rb. These cases pin that the
# Params the layer builds, children included, answer the reopened methods,
# and that ParameterMissing is still a 400 once the layer no longer names it
# (cybertrain/context.rb registers it, hence that require).

BOUNDARY = "----WebKitFormBoundarySplit42"

# test/multipart.rb's part builder, cut to what these cases send.
def raw_part(boundary, headers, data)
  out = "".b
  out << "--".b
  out << boundary.b
  out << "\r\n".b
  out << headers.b
  out << "\r\n\r\n".b
  out << data.b
  out << "\r\n".b
  out
end

def text_part(boundary, name, value)
  raw_part(boundary, "Content-Disposition: form-data; name=\"#{name}\"", value)
end

def file_part(boundary, name, filename, type, data)
  raw_part(boundary, "Content-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\nContent-Type: #{type}", data)
end

def closing(boundary)
  "--#{boundary}--\r\n".b
end

test "a nested child Query built answers permit, nested filters included" do
  params = Cybertrain::Query.parse("a[b][c]=1&a[t][]=x&a[t][]=y")
  permitted = params.nested("a").permit(b: [:c], t: [])
  assert_equal({ "b" => { "c" => "1" }, "t" => ["x", "y"] }, permitted)
end

test "require on a missing key raises ParameterMissing, which is a 400" do
  params = Cybertrain::Query.parse("a=1")
  status = 0
  message = ""
  begin
    params.require(:missing)
  rescue Cybertrain::Params::ParameterMissing => e
    message = e.message
    status = Cybertrain::ClientError.status_for(e)
  end
  assert_equal "param is missing or the value is empty: missing", message
  assert_equal 400, status
end

test "a multipart file and text field under one key: upload? sees the file, permit only the text" do
  body = "".b
  body << file_part(BOUNDARY, "user[avatar]", "a.png", "image/png", "\x89PNG\r\n".b)
  body << text_part(BOUNDARY, "user[name]", "ann")
  body << closing(BOUNDARY)
  form = Cybertrain::Multipart.parse(body, "multipart/form-data; boundary=#{BOUNDARY}")
  params = Cybertrain::Params.new
  Cybertrain::Multipart.fill(params, form)
  assert params.nested("user").upload?("avatar")
  assert_equal({ "name" => "ann" }, params.nested("user").permit(:name))
end
