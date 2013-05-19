#!/usr/bin/env ruby

root = File.expand_path File.dirname(__FILE__)

push_to_github = (ARGV == %w(push))

def cmd(cmd)
  puts ">> #{cmd}"
  system cmd or raise "#{cmd} failed"
end

unless File.exist? "#{root}/yardoc/.git"
  Dir.chdir "#{root}/yardoc" do
    cmd 'git clone --single-branch --branch gh-pages git@github.com:pitr-ch/actress.git .'
  end
end

message = nil
Dir.chdir(root) do
  p message = `git log -n 1 --oneline`.strip
  cmd 'yard doc'
end

Dir.chdir "#{root}/yardoc" do
  cmd 'git checkout gh-pages'
  if push_to_github
    cmd "git ac -m '#{message}'"
    cmd 'git push origin gh-pages'
  end
end
