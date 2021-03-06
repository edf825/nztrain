class JudgeSubmissionWorker < ApplicationWorker
  extend GCWorkerMiddleware

  default_queue :judge

  def self.judge(submission, queue: nil, delay: 0)
    self.put(id: submission.id, queue: queue, delay: delay)
  end


  def self.perform(job)
    result = self.new(job).perform
    job.complete
  end

  def perform
    self.submission = Submission.find(job.data['id'])
    judge_start_time = Time.now
    result = judge

    submission.with_lock do # This block is called within a transaction,
      submission.reload # todo: fetch only columns needed
      submission.judge_log = result.to_json
      submission.score = result['score']
      submission.judged_at = judge_start_time
      submission.save
    end
  rescue StandardError => e
    unless self.submission.nil?
      submission.reload
      submission.judge_log = {'error' => {'message' => e.message, 'backtrace' => e.backtrace}}.to_json
      submission.save
    end
    raise
  end

  ExeFileName = "program.exe"
  EvalFileName = "eval.sh"
  StackLimit = 1024 * 4 # 4 MB
  OutputBaseLimit = 1024 * 1024 * 2

  attr_accessor :submission, :job

  def initialize(job)
    self.job = job
  end

  def judge
    result = {}
    setup_judging do
      if submission.language.interpreted
        File.open(File.expand_path(ExeFileName, tmpdir),"w") { |f| f.write(submission.source) }
        run_command = submission.language.compile_command(:source => ExeFileName)
      else
        result['compile'] = compile!(ExeFileName) # possible caching
        return result.merge!(grade_compile_error(result['compile'])) if result['compile']['stat'] != 0 #error

        run_command = "./#{ExeFileName}"
      end

      result['test_cases'] = {}
      result['test_sets'] = {}
      denominator = problem.test_sets.map(&:points).inject(&:+).to_f

      resource_limits = { :mem => memory_limit*1024, :time => time_limit, :extra_time => extra_time, :wall_time => wall_time, :stack => StackLimit, :processes => false }

      # prerequisites
      prereqs = problem.test_cases.where(:id => problem.prerequisite_sets.joins(:test_case_relations).select(:test_case_relations => :test_case_id))

      prereqs.each do |test_case|
        result['test_cases'][test_case.id] = judge_test_case(test_case, run_command, resource_limits) unless result['test_cases'].has_key?(test_case.id)
      end

      problem.prerequisite_sets.each do |test_set|
        result['test_sets'][test_set.id] = grade_test_set(test_set, result['test_cases'], denominator)
      end

      unless problem.prerequisite_sets.empty?
        result['prerequisites'] = preres = grade_prerequisites(result['test_sets'])
        return result.merge('status' => preres['status']) if preres['status'] != 0
        return result.merge('status' => 0, 'evaluation' => 0, 'score' => 0) if preres['evaluation'] != 1
      end

      # test cases
      (problem.test_cases - prereqs).each do |test_case|
        result['test_cases'][test_case.id] = judge_test_case(test_case, run_command, resource_limits) unless result['test_cases'].has_key?(test_case.id)
      end

      # test sets
      problem.test_sets.each do |test_set|
        result['test_sets'][test_set.id] = grade_test_set(test_set, result['test_cases'], denominator) unless result['test_sets'].has_key?(test_set.id)
      end
      
      result.merge!(grade_submission(result['test_sets'], denominator, preres))
    end
    result
  end

  private
  attr_accessor :problem, :box, :tmpdir

  def time_limit
    problem.time_limit || 0.001
  end

  def memory_limit
    problem.memory_limit || 0.001
  end

  def extra_time
    (Submission::CLASSIFICATION[:inefficient] == submission.classification) ? time_limit*2 : [time_limit*0.5, (20.0/[problem.test_cases.count, 1.0].max)].min
  end

  def wall_time
    time_limit*3+extra_time+5
  end

  def setup_judging
    self.problem = submission.problem
    Dir.mktmpdir do |tmpdir|
      self.tmpdir = tmpdir
      Isolate.box do |box|
        self.box = box
        yield
      end or raise Isolate::LockError, "Error locking box"
    end
  end

  def compile! output
    result = submission.language.compile(box, submission.source, output, :mem => 262144, :wall_time => 60)
    FileUtils.copy(box.expand_path(output), File.expand_path(output, tmpdir)) if result['stat'] == 0
    return result
  ensure
    box.clean!
  end

  def judge_test_case(test_case, run_command, resource_limits)
    FileUtils.copy(File.expand_path(ExeFileName, tmpdir), box.expand_path(ExeFileName))
    result = run_test_case(test_case, run_command, resource_limits)
    result['evaluator'] = evaluate_output(test_case, result['output'], result['output_size'], problem.evaluator)
    result['log'] = truncate_output(result['log']) # log only a small portion
    result['output'] = truncate_output(result['output'].slice(0,100)) # store only a small portion
    result
  end

  def run_test_case(test_case, run_command, resource_limits = {})
    stream_limit = OutputBaseLimit + test_case.output.bytesize*2
    run_opts = resource_limits.reverse_merge(:output_limit => stream_limit, :clean_utf8 => true)
    if submission.input.nil?
      run_opts[:stdin_data] = test_case.input
    else
      box.fopen(submission.input,"w") { |f| f.write(test_case.input) }
    end
    r={}
    (r['output'], r['output_size']), (r['log'], r['log_size']), (r['box'],), r['meta'], r['stat'] = box.capture5(run_command, run_opts)
    r['stat'] = r['stat'].exitstatus
    r['time'] = [r['meta']['time'],time_limit.to_f].min
    unless submission.output.nil?
      if box.exist?(submission.output)
        box.fopen(submission.output) { |f| r['output'], r['output_size'] = box.read_pipe_limited(f, stream_limit) }
      else
        r['output'] = ""
        r['output_size'] = 0
      end
    end
    return r
  ensure
    box.clean!
  end

  def evaluate_output(test_case, output, output_size, evaluator)
    stream_limit = OutputBaseLimit + test_case.output.bytesize*2
    if output_size > stream_limit
      return {'evaluation' => 0, 'log' => "Output exceeded the streamsize limit of #{stream_limit}.", 'meta' => {'status' => 'OK'}}
    end
    expected = conditioned_output(test_case.output)
    actual = conditioned_output(output)
    if evaluator.nil?
      {'evaluation' => (actual == expected ? 1 : 0), 'meta' => {'status' => 'OK'}}
    else
      r = {}
      box.fopen(EvalFileName,"w") do |file|
        file.chmod(0700)
        file.write(problem.evaluator.source.gsub(/\r\n?/, "\n"))
      end
      resource_limits = { :mem => 262144, :time => time_limit*3, :wall_time => time_limit*3+30 }
      box.fopen("actual","w") { |f| f.write(actual) } # DEPRECATED
      box.fopen("input","w") { |f| f.write(test_case.input) } # DEPRECATED
      box.fopen("expected","w") { |f| f.write(expected) } # DEPRECATED
      deprecated_args = "input actual expected" # DEPRECATED
      eval_output = nil
      str_to_pipe(test_case.input, expected) do |input_stream, output_stream|
        run_opts = resource_limits.reverse_merge(:processes => true, 3 => input_stream, 4 => output_stream, :stdin_data => actual, :output_limit => OutputBaseLimit + test_case.output.bytesize*4, :clean_utf8 => true)
        (stdout,), (r['log'],r['log_size']), (r['box'],), r['meta'], status = box.capture5("./#{EvalFileName} #{deprecated_args}", run_opts )
        r['log'] = truncate_output(r['log'])
        return r.merge('stat' => 2, 'box' => 'Output was not a valid UTF-8 encoding\n'+r['box']) if !output.force_encoding("UTF-8").valid_encoding?
        eval_output = stdout.strip.split(nil,2)
        r['stat'] = status.exitstatus
      end
      if eval_output.empty? # DEPRECATED
        if r['stat'] == 1 && r['meta']['status'] == 'RE' && r['meta']['exitcode'] == 1 # DEPRECATED
          r['evaluation'] = 0 
          r['meta']['status'] = 'OK'
        end
        r['evaluation'] = 1 if r['stat'] == 0 # DEPRECATED
      else
        r['evaluation'] = eval_output[0].to_f
        r['message'] = truncate_output(eval_output[1] || "")
        r.delete('evaluation') if r['meta']['status'] != 'OK'
      end
      r['message'] = "No output.\n#{r['message']}" if output == ""
      r
    end
  ensure
    box.clean!
  end

  def grade_test_set test_set, evaluated_test_cases, denominator
    result = {'cases' => []}
    pending, error, sig = false, false, false
    evaluations = test_set.test_case_relations.map do |relation|
      id = relation.test_case_id
      result['cases'] << id
      next pending = true unless evaluated_test_cases.has_key?(id)
      test = evaluated_test_cases[id]
      break error = true if ((test['evaluator']||{})['meta']||{})['status'] != 'OK' || !test['evaluator'].has_key?('evaluation')
      sig = true if test['stat'] != 0
      test['evaluator'].fetch('evaluation', 0)
    end

    result['status'] = 0
    result['status'] = 1 if pending
    result['status'] = 2 if error
    if result['status'] == 0
      # test set = min case score
      result['evaluation'] = evaluations.push(1).min
      result['evaluation'] = 0 if sig # any signal/runtime error/timeout fails the test set
      result['score'] = (test_set.points * result['evaluation']).to_f*100/denominator
    end
    result
  end

  def grade_prerequisites(graded_sets)
    sets = graded_sets.values_at(*problem.prerequisite_set_ids)
    r = {}
    r['status'] = combined_status(sets)
    r['evaluation'] = sets.map{ |s| s['evaluation'] }.sum.to_f/sets.size if r['status'] == 0
    r
  end

  def grade_submission(graded_sets, denominator, preres = nil)
    result = {}
    result['prerequisites'] = preres = grade_prerequisites(graded_sets) if preres.nil? && !problem.prerequisite_set_ids.empty?
    test_sets = problem.test_sets
    sets = graded_sets.values_at(*test_sets.map(&:id))
    result['status'] = combined_status(sets)
    if result['status'] == 0
      numerator = test_sets.map{ |s| (graded_sets[s.id]['evaluation'] * s.points)}.inject(&:+).to_f
      result['evaluation'] = numerator/denominator
      if denominator == 0
        result['score'] = 0
      else
        result['score'] = (preres.nil? || preres['evaluation'] == 1) ? (result['evaluation']*100).floor : 0
      end
    end
    result
  end

  def combined_status(sets)
    [*sets.map{ |s| s['status'] }, (sets.compact.count<sets.count) ? 1 : 0].max
  end

  def grade_compile_error(compiled)
    case compiled['stat']
    when 0
      return { 'status' => 1 } # pending
    when 1
      return { 'status' => 0, 'evaluation' => 0.0, 'score' => 0 }
    else
      return { 'status' => 2 } # errored
    end
  end

  # Utility methods
  def str_to_pipe(*strings)
    pipes = strings.map do |str|
      r, w = IO.pipe
      Thread.new do # to avoid full pipe deadlocks
        begin
          w.write(str)
        rescue Errno::EPIPE
        ensure
          w.close
        end
      end
      r
    end
    result = yield *pipes
    pipes.each(&:close)
    result
  end

  def conditioned_output output
    # canonicalize based on how it looks - remove trailing whitespace, keep leading whitespace
    output.split("\n").map{|s|s.rstrip}.join("\n").rstrip << "\n"
  end
  
  def truncate_output output
    self.class.truncate_output(output)
  end

  def self.truncate_output output
    output.slice(0,100).split("\n",-1).take(10).join("\n").tap do |out|
      out << "..." if out.size < output.size
    end
  end

end
