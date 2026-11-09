# A grandchild of Cybertrain::Job::Base: it inherits Admin::ReportJob's
# perform and, after its own discard_on KeyError, its policies (the retry
# on StandardError, then the discard on ArgumentError).
class DigestJob < Admin::ReportJob
  discard_on KeyError
end
