require 'redis'
require 'redis/connection/hiredis'

class RedisClient
  class << self
    @redis = (Thread.current[:isu_redis] ||= Redis.new(path: '/tmp/redis.sock'))
  end
end
