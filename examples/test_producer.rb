require 'rubygems'
$:.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
require 'juggler'

# Throw some jobs

10.times do |i|
  path = ['/fast', '/slow'][i % 2]
  Juggler.throw(:http, path)
end
10.times { Juggler.throw(:timer, {:foo => 'bar'}) }
