require "airbrake_tools/version"
require "airbrake-api"

module AirbrakeTools
  DEFAULT_HOT_PAGES = 1
  DEFAULT_NEW_PAGES = 1
  DEFAULT_LIST_PAGES = 10
  DEFAULT_SUMMARY_PAGES = 10
  DEFAULT_COMPARE_DEPTH_ADDITION = 3 # first line in project is 6 -> compare at 6 + x depth
  DEFAULT_ENVIRONMENT = "production"
  COLORS = {
    :gray => "\e[0;37m",
    :green => "\e[0;32m",
    :bold => "\e[1m",
    :clear => "\e[0m"
  }
  HOUR = 60*60

  class << self
    def cli(argv)
      options = extract_options(argv)

      AirbrakeAPI.account = ARGV[0]
      AirbrakeAPI.auth_token = ARGV[1]
      AirbrakeAPI.secure = true

      options[:project_id] = project_id(options.delete(:project_name)) if options[:project_name]

      if AirbrakeAPI.account.to_s.empty? || AirbrakeAPI.auth_token.to_s.empty?
        puts "Usage instructions: airbrake-tools --help"
        return 1
      end

      case ARGV[2]
      when "hot"
        print_errors(hot(options))
      when "list"
        list(options)
      when "summary"
        summary(ARGV[3] || raise("Need error id"), options)
      when "new"
        print_errors(new(options))
      when "open"
        open(ARGV[3] || raise("Need error id"), ARGV[4])
      else
        raise "Unknown command #{ARGV[2].inspect} try hot/new/list/summary/open"
      end
      return 0
    end

    def hot(options = {})
      errors = Array(options[:project_id] || projects.map(&:id)).flat_map do |project_id|
        errors_with_notices({pages: DEFAULT_HOT_PAGES, project_id: project_id}.merge(options))
      end
      errors.sort_by{|_,_,f| f }.reverse[0...AirbrakeAPI::Client::PER_PAGE]
    end

    def new(options = {})
      need_project_id!(options)
      errors = errors_with_notices({:pages => DEFAULT_NEW_PAGES}.merge(options))
      errors.sort_by{|e,_,_| e.created_at }.reverse
    end

    def errors_with_notices(options)
      add_notices_to_pages(errors_from_pages(options))
    end

    def list(options)
      need_project_id!(options)
      list_pages = (options[:pages] ? options[:pages] : DEFAULT_LIST_PAGES)
      page = 1
      while page <= list_pages && errors = AirbrakeAPI.errors(page: page, project_id: options.fetch(:project_id))
        select_env(errors, options).each do |error|
          puts "#{error.id} -- #{error.error_class} -- #{error.error_message} -- #{error.created_at}"
        end
        $stderr.puts "Page #{page} ----------\n"
        page += 1
      end
    end

    def summary(error_id, options)
      notices = AirbrakeAPI.notices(error_id, :pages => options[:pages] || DEFAULT_SUMMARY_PAGES)

      puts "last retrieved notice: #{((Time.now - notices.last.created_at) / (60 * 60)).round} hours ago at #{notices.last.created_at}"
      puts "last 2 hours:  #{sparkline(notices, :slots => 60, :interval => 120)}"
      puts "last day:      #{sparkline(notices, :slots => 24, :interval => 60 * 60)}"

      grouped_backtraces(notices, options).sort_by{|_,notices| notices.size }.reverse.each_with_index do |(backtrace, notices), index|
        puts "Trace #{index + 1}: occurred #{notices.size} times e.g. #{notices[0..5].map(&:id).join(", ")}"
        puts notices.first.error_message
        puts backtrace.map{|line| present_line(line) }
        puts ""
      end

      if options[:params]
        puts "Parameters:"
        notices.each do |notice|
          # Print each set of parameters with a stable output order.
          h = notice.request.params.to_hash
          puts "#{notice.uuid.inspect}=>{" + h.sort.map{|k,v| "#{k.inspect}=>#{v.inspect}"}.join(", ") + "}" unless h.nil?
        end
      end
    end

    def open(error_id, notice_id=nil)
      require "launchy"
      error = AirbrakeAPI.error(error_id)
      raise URI::InvalidURIError if error.nil?

      url = "https://#{AirbrakeAPI.account}.airbrake.io/projects/#{error.project_id}/groups/#{error_id}"
      url += "/notices/#{notice_id}" if notice_id
      Launchy.open url
    rescue URI::InvalidURIError
      puts "Error id does not map to any error on Airbrake"
    end

    private

    def need_project_id!(options)
      raise "Need a project_id" unless options[:project_id]
    end

    def present_line(line)
      color = :gray if $stdout.tty? && !custom_file?(line)
      line = line.sub("[PROJECT_ROOT]/", "")
      line = add_blame(line)

      color ? color_text(line, color) : line
    end

    def add_blame(backtrace_line)
      file, line = backtrace_line.split(":", 2)
      line = line.to_i
      if not file.start_with?("/") and line > 0 and File.exist?(".git") and File.exist?(file)
        result = `git blame #{file} -L #{line},#{line} --show-email -w 2>&1`
        if $?.success?
          result.sub!(/ #{line}\) .*/, " )") # cut of source code
          backtrace_line += " -- #{result.strip}"
        end
      end
      backtrace_line
    end

    def grouped_backtraces(notices, options)
      notices = notices.compact.select { |n| backtrace(n) }

      compare_depth = if options[:compare_depth]
        options[:compare_depth]
      else
        average_first_project_line(notices.map { |n| backtrace(n) }) +
          DEFAULT_COMPARE_DEPTH_ADDITION
      end

      notices.group_by do |notice|
        backtrace(notice)[0..compare_depth]
      end
    end

    def backtrace(notice)
      return if notice.backtrace.is_a?(String)
      [*notice.backtrace.first[1]] # can be string or array
    end

    def average_first_project_line(backtraces)
      depths = backtraces.map do |backtrace|
        backtrace.index { |line| custom_file?(line) }
      end.compact
      return 0 if depths.size == 0
      depths.inject(:+) / depths.size
    end

    def custom_file?(line)
      line.start_with?("[PROJECT_ROOT]") && !line.start_with?("[PROJECT_ROOT]/vendor/")
    end

    def add_notices_to_pages(errors)
      Parallel.map(errors, :in_threads => 10) do |error|
        begin
          pages = 1
          notices = AirbrakeAPI.notices(error.id, pages: pages, raw: true).compact
          print "."
          [error, notices, frequency(notices, pages * AirbrakeAPI::Client::PER_PAGE)]
        rescue Faraday::Error::ParsingError
          $stderr.puts "Ignoring #{hot_summary(error)}, got 500 from http://#{AirbrakeAPI.account}.airbrake.io/errors/#{error.id}"
        rescue Exception => e
          puts "Ignoring exception <<#{e}>>, most likely bad data from airbrake"
        end
      end.compact
    end

    def errors_from_pages(options)
      errors = []
      options[:pages].times do |i|
        errors.concat(AirbrakeAPI.errors(:page => i+1, :project_id => options[:project_id]) || [])
      end
      select_env(errors, options)
    end

    def select_env(errors, options)
      errors.select{|e| e.rails_env == (options[:env] || DEFAULT_ENVIRONMENT) }
    end

    def print_errors(hot)
      hot.each_with_index do |(error, notices, rate), index|
        spark = sparkline(notices, :slots => 60, :interval => 60)
        puts "\n##{(index+1).to_s.ljust(2)} #{rate.round(2).to_s.rjust(6)}/hour total:#{error.notices_count.to_s.ljust(8)} #{color_text(spark.ljust(61), :green)}"
        puts hot_summary(error)
      end
    end

    # we only have a limited sample size, so we do not know how many errors occurred in total
    def frequency(notices, expected_notices)
      return 0 if notices.empty?
      range = if notices.size < expected_notices && notices.last.created_at > (Time.now - HOUR)
        HOUR # we got less notices then we wanted -> very few errors -> low frequency
      else
        Time.now - notices.map{ |n| n.created_at }.min
      end
      errors_per_second = notices.size / range.to_f
      (errors_per_second * HOUR).round(2) # errors_per_hour
    end

    def hot_summary(error)
      "id: #{color_text(error.id, :bold)} -- first: #{color_text(error.created_at, :bold)} -- #{error.error_message}"
    end

    def color_text(text, color)
      "#{COLORS[color]}#{text}#{COLORS[:clear]}"
    end

    def extract_options(argv)
      options = {}
      OptionParser.new do |opts|
        opts.banner = <<-BANNER.gsub(" "*12, "")
            Power tools for airbrake.

            hot: list hottest errors
            list: list errors 1-by-1 so you can e.g. grep -> search
            summary: analyze occurrences and backtrace origins
            open: opens specified error in your default browser

            Usage:
                airbrake-tools subdomain auth-token command [options]
                  auth-token: go to airbrake -> settings, copy your auth-token

            Options:
        BANNER
        opts.on("-c NUM", "--compare-depth NUM", Integer, "How deep to compare backtraces in summary (default: first line in project + #{DEFAULT_COMPARE_DEPTH_ADDITION})") {|s| options[:compare_depth] = s }
        opts.on("-p NUM", "--pages NUM", Integer, "How maybe pages to iterate over (default: hot:#{DEFAULT_HOT_PAGES} new:#{DEFAULT_NEW_PAGES} summary:#{DEFAULT_SUMMARY_PAGES})") {|s| options[:pages] = s }
        opts.on("-e ENV", "--environment ENV", String, "Only show errors from this environment (default: #{DEFAULT_ENVIRONMENT})") {|s| options[:env] = s }
        opts.on("--project NAME_OR_ID", String, "Name of project to fetch errors for") {|p| options[:project_name] = p }
        opts.on("-h", "--help", "Show this.") { puts opts; exit }
        opts.on("-v", "--version", "Show Version"){ puts "airbrake-tools #{VERSION}"; exit }
        opts.on("--params", "Show params for summary.") { options[:params] = true }
      end.parse!(argv)
      options
    end

    def sparkline_data(notices, options)
      last = notices.last.created_at
      now = notices.map(&:created_at).push(Time.now).max # adjust now if airbrakes clock is going too fast

      Array.new(options[:slots]).each_with_index.map do |_, i|
        slot_end = now - (i * options[:interval])
        slot_start = slot_end - 1 * options[:interval]
        next if last > slot_end # do not show empty lines when we actually have no data
        notices.select { |n| n.created_at.between?(slot_start, slot_end) }.size
      end
    end

    def sparkline(notices, options)
      `#{File.expand_path('../../spark.sh',__FILE__)} #{sparkline_data(notices, options).join(" ")}`.strip
    end

    def projects
      @projects ||= AirbrakeAPI.projects
    end

    def project_id(project_name)
      return project_name.to_i if project_name =~ /^\d+$/
      project = projects.detect { |p| p.name == project_name }
      raise "project with name #{project_name} not found try #{projects.map(&:name).join(", ")}" unless project
      project.id
    end
  end
end
