class ApplicationController < ActionController::Base
  protect_from_forgery
  around_filter :thread_clear
  around_filter :thread_with_api_token, :except => [:render_exception, :render_not_found]
  before_filter :find_object_by_uuid, :except => [:index, :render_exception, :render_not_found]

  begin
    rescue_from Exception,
    :with => :render_exception
    rescue_from ActiveRecord::RecordNotFound,
    :with => :render_not_found
    rescue_from ActionController::RoutingError,
    :with => :render_not_found
    rescue_from ActionController::UnknownController,
    :with => :render_not_found
    rescue_from ::AbstractController::ActionNotFound,
    :with => :render_not_found
  end

  def unprocessable(message=nil)
    @errors ||= []
    @errors << message if message
    render_error status: 422
  end

  def render_error(opts)
    respond_to do |f|
      f.html { render opts.merge(controller: 'application', action: 'error') }
      f.json { render opts.merge(json: {success: false, errors: @errors}) }
    end
  end

  def render_exception(e)
    logger.error e.inspect
    logger.error e.backtrace.collect { |x| x + "\n" }.join('') if e.backtrace
    if @object.andand.errors.andand.full_messages.andand.any?
      @errors = @object.errors.full_messages
    else
      @errors = [e.inspect]
    end
    self.render_error status: 422
  end

  def render_not_found(e=ActionController::RoutingError.new("Path not found"))
    logger.error e.inspect
    @errors = ["Path not found"]
    self.render_error status: 404
  end


  def index
    @objects ||= model_class.all
    respond_to do |f|
      f.json { render json: @objects }
      f.html { render }
    end
  end

  def show
    if !@object
      return render_not_found("object not found")
    end
    respond_to do |f|
      f.json { render json: @object }
      f.html { render }
    end
  end

  def render_content
    if !@object
      return render_not_found("object not found")
    end
  end

  def new
    @object = model_class.new
  end

  def update
    updates = params[@object.class.to_s.underscore.singularize.to_sym]
    updates.keys.each do |attr|
      if @object.send(attr).is_a? Hash and updates[attr].is_a? String
        updates[attr] = Oj.load updates[attr]
      end
    end
    if @object.update_attributes updates
      show
    else
      self.render_error status: 422
    end
  end

  def create
    @object ||= model_class.new params[model_class.to_s.singularize.to_sym]
    @object.save!
    redirect_to @object
  end

  def destroy
    if @object.destroy
      redirect_to(params[:return_to] || :back)
    else
      self.render_error status: 422
    end
  end

  def current_user
    if Thread.current[:arvados_api_token]
      Thread.current[:user] ||= User.current
    else
      logger.error "No API token in Thread"
      return nil
    end
  end

  def model_class
    controller_name.classify.constantize
  end

  protected
    
  def find_object_by_uuid
    if params[:id] and params[:id].match /\D/
      params[:uuid] = params.delete :id
    end
    if params[:uuid].is_a? String
      @object = model_class.find(params[:uuid])
    else
      @object = model_class.where(uuid: params[:uuid]).first
    end
  end

  def thread_clear
    Thread.current[:arvados_api_token] = nil
    Thread.current[:user] = nil
    yield
  end

  def thread_with_api_token
    begin
      try_redirect_to_login = true
      if params[:api_token]
        try_redirect_to_login = false
        Thread.current[:arvados_api_token] = params[:api_token]
        # Before copying the token into session[], do a simple API
        # call to verify its authenticity.
        if verify_api_token
          session[:arvados_api_token] = params[:api_token]
          if !request.format.json? and request.method == 'GET'
            # Repeat this request with api_token in the (new) session
            # cookie instead of the query string.  This prevents API
            # tokens from appearing in (and being inadvisedly copied
            # and pasted from) browser Location bars.
            redirect_to request.fullpath.sub(%r{([&\?]api_token=)[^&\?]*}, '')
          else
            yield
          end
        else
          @errors = ['Invalid API token']
          self.render_error status: 401
        end
      elsif session[:arvados_api_token]
        # In this case, the token must have already verified at some
        # point, but it might have been revoked since.  We'll try
        # using it, and catch the exception if it doesn't work.
        try_redirect_to_login = false
        Thread.current[:arvados_api_token] = session[:arvados_api_token]
        begin
          yield
        rescue ArvadosApiClient::NotLoggedInException
          try_redirect_to_login = true
        end
      else
        logger.debug "No token received, session is #{session.inspect}"
      end
      if try_redirect_to_login
        respond_to do |f|
          f.html {
            if request.method == 'GET'
              redirect_to $arvados_api_client.arvados_login_url(return_to: request.url)
            else
              flash[:error] = "Either you are not logged in, or your session has timed out. I can't automatically log you in and re-attempt this request."
              redirect_to :back
            end
          }
          f.json {
            @errors = ['You do not seem to be logged in. You did not supply an API token with this request, and your session (if any) has timed out.']
            self.render_error status: 422
          }
        end
      end
    ensure
      # Remove token in case this Thread is used for anything else.
      Thread.current[:arvados_api_token] = nil
    end
  end

  def verify_api_token
    begin
      Link.where(uuid: 'just-verifying-my-api-token')
      true
    rescue ArvadosApiClient::NotLoggedInException
      false
    end
  end

  def ensure_current_user_is_admin
    unless current_user and current_user.is_admin
      @errors = ['Permission denied']
      self.render_error status: 401
    end
  end
end
