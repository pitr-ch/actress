Gem::Specification.new do |s|

  s.name        = 'actress'
  s.version     = '0.0.1'
  s.date        = '2013-03-26'
  s.summary     = 'Simple Actor library'
  s.description = <<-TEXT
    Provides Future and Actors. Actors can have dedicated thread (Actor::Threaded) or they can share
    thread pool (Actor::Shared). You can create as many shared actors as you need
    (this is not supported by other libs like Celluloid).
  TEXT
  s.authors          = ['Petr Chalupa']
  s.email            = 'git@pitr.ch'
  s.homepage         = 'https://github.com/pitr-ch/actress'
  s.extra_rdoc_files = %w(MIT-LICENSE)
  s.files            = Dir['lib/actress.rb']
  s.require_paths    = %w(lib)
  s.test_files       = Dir['spec/actress.rb']

  { 'logging'   => nil,
    'algebrick' => nil
  }.each do |gem, version|
    s.add_runtime_dependency(gem, [version || '>= 0'])
  end

  { 'minitest' => '< 5',
    'turn'     => nil,
    'pry'      => nil,
    'yard'     => nil,
    'kramdown' => nil,
  }.each do |gem, version|
    s.add_development_dependency(gem, [version || '>= 0'])
  end
end

