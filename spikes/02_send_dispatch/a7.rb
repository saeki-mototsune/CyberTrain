# SPIKE (throwaway): workaround for top-level/local receivers - route through a method with self.send
class B
  def hi; 1; end
  def dispatch(m); self.send(m); end
end
class S < B; def yo; 2; end; end
c = S.new
arr = [:yo, :hi]
p c.dispatch(arr[0])
p c.dispatch(arr[1])
p c.public_send(:yo)
