Gem::Specification.new do |s|

  s.name        = 'actress'
  s.version     = File.read(File.join(File.dirname(__FILE__), 'VERSION'))
  s.date        = '2013-07-18'
  s.summary     = 'Actor model library'
  s.description = <<-TEXT.gsub(/^ +|/, '')
    |Provides Future and Actors. Actors are sharing Thread pool so
    |as many actors as you need can be spawned.
  TEXT
  s.authors          = ['Petr Chalupa']
  s.email            = 'git@pitr.ch'
  s.homepage         = 'https://github.com/pitr-ch/actress'
  s.extra_rdoc_files = %w(LICENSE.txt README.md)
  s.files            = Dir['lib/actress.rb']
  s.require_paths    = %w(lib)
  s.test_files       = Dir['spec/actress.rb']
  s.license          = 'Apache License 2.0'

  { 'algebrick' => '~> 0.4.0',
    'justified' => nil,
    'atomic'    => nil
  }.each do |gem, version|
    s.add_runtime_dependency(gem, [version || '>= 0'])
  end

  { 'minitest'           => nil,
    'minitest-reporters' => nil,
    'turn'               => nil,
    'pry'                => nil,
    'yard'               => nil,
    'kramdown'           => nil
  }.each do |gem, version|
    s.add_development_dependency(gem, [version || '>= 0'])
  end
end

