module Outer
  module Net
    class TimeoutError < StandardError; end
  end
end
class AppError < StandardError; end

def inner(log)
  begin
    raise AppError, "boom"
  rescue Outer::Mailer::TimeoutError => e
    log << "arm Mailer"
  rescue AppError => e
    log << "arm AppError"
  end
  nil
end

log = []
begin
  inner(log)
rescue StandardError => e
  log << e.class.name
end
p log
