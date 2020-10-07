Resque::Server.helpers do
  def long_job_enabled?
    Object.const_defined?(:LongJob)
  end

  def long_job?(args)
    return false unless long_job_enabled?
    return false unless args&.size == 1

    UUID.validate(args[0])
  end

  def get_long_job(args)
    uuid = args[0]

    LongJobRun.get_by_uuid(uuid).first
  end

  def smart_args(args)
    return args unless long_job?(args)

    get_long_job(args)&.args
  end

  def long_job_site_id(args)
    return nil unless long_job?(args)

    get_long_job(args)&.site_id
  end
end
