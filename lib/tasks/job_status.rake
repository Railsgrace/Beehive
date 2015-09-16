namespace :job_status do
  desc "Closing past due jobs..."
  task :close => :environment do
    Job.all.where.not(status: 1).each do |j|
      if j.latest_start_date < Time.now
        j.update(status: 1)
      end
    end
  end

  desc "init job status..."
  task :init => :environment do
    Job.all.where(status: nil).each do |j|
      if j.latest_start_date < Time.now
        j.update(status: 1)
      else
        j.update(status: 0)
      end
    end
  end
end