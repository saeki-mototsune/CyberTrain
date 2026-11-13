require "test_helper"

# config/app.rb's scheduled task "prune done jobs": every comment leaves a
# `done` NotifyCommentJob row, and the rows done more than 7 days ago are
# deleted; failed rows stay for the jobs page.
class PruneDoneJobsTest < ActiveSupport::TestCase
  test "config/app.rb schedules the prune of done jobs, which keeps the last 7 days" do
    index = Cybertrain::Scheduler.task_index("prune done jobs")
    assert index >= 0, "expected the task \"prune done jobs\""
    old = BlogTestHelper.done_job(8)
    recent = BlogTestHelper.done_job(6)
    failed = BlogTestHelper.failed_job
    Cybertrain::DB.with { |c| c.execute("UPDATE cybertrain_jobs SET updated_at = 0 WHERE id = ?", [failed]) }
    assert Cybertrain::Scheduler.run_task(Cybertrain::Scheduler::TASKS[index]), "the task ran without raising"
    assert_equal "(gone)", BlogTestHelper.job_state(old)
    assert_equal "done", BlogTestHelper.job_state(recent)
    assert_equal "failed", BlogTestHelper.job_state(failed)
  end

  # The task reads Time.current, so it follows the travel helpers: a row
  # done now is still there exactly 7 days later and gone a day after.
  test "a row done today is kept for 7 days and pruned after them" do
    index = Cybertrain::Scheduler.task_index("prune done jobs")
    freeze_time
    today = BlogTestHelper.done_job(0)
    travel 7.days
    assert Cybertrain::Scheduler.run_task(Cybertrain::Scheduler::TASKS[index]), "the task ran without raising"
    assert_equal "done", BlogTestHelper.job_state(today)
    travel 1.day
    assert Cybertrain::Scheduler.run_task(Cybertrain::Scheduler::TASKS[index]), "the task ran without raising"
    assert_equal "(gone)", BlogTestHelper.job_state(today)
  end
end
