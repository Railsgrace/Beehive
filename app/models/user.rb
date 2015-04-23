require 'digest/sha1'

class User < ActiveRecord::Base

  # === List of columns ===
  #   id                  : integer 
  #   name                : string 
  #   login               : string 
  #   email               : string 
  #   persistence_token   : string 
  #   single_access_token : string 
  #   perishable_token    : string 
  #   login_count         : integer 
  #   failed_login_count  : integer 
  #   last_request_at     : datetime 
  #   current_login_at    : datetime 
  #   last_login_at       : datetime 
  #   current_login_ip    : string 
  #   last_login_ip       : string 
  #   user_type           : integer 
  #   units               : integer 
  #   free_hours          : integer 
  #   research_blurb      : text 
  #   experience          : string 
  #   summer              : boolean 
  #   url                 : string 
  #   year                : integer 
  # =======================

  include AttribsHelper

  # Authlogic
  acts_as_authentic do |c|
    #c.merge_validates_length_of_login_field_options :within => 1..100
    # so that logins can be 1 character in length even; 'login' is provided
    # by CAS so we don't want to artificially limit the values we get for it.

    c.validate_email_field = false
    c.validate_login_field = false
  end

  # Simplification of LDAP roles where earlier Types take priority
  # Default UI: Undergrad apply to research, others post research
  class Types
    Undergrad = 0
    Grad      = 1
    Faculty   = 2
    Staff     = 3
    Affiliate = 4
    Admin     = 5
    All       = [Undergrad, Grad, Faculty, Staff, Affiliate, Admin]
  end

  has_many :jobs,          :dependent => :nullify
  has_many :owns,          :dependent => :destroy
  has_many :owned_jobs,    :through => :owns, :source => :job

  has_many :applics
  has_many :applied_jobs,  :through => :applics, :source => :job

  has_many :watches,       :dependent => :destroy
  has_many :watched_jobs,  :through => :watches, :source => :job

  has_one  :resume,        :class_name => 'Document', :conditions => {:document_type => Document::Types::Resume}, :dependent => :destroy
  has_one  :transcript,    :class_name => 'Document', :conditions => {:document_type => Document::Types::Transcript}, :dependent => :destroy
  has_many :enrollments,   :dependent => :destroy
  has_many :courses,       :through => :enrollments
  has_many :interests,     :dependent => :destroy
  has_many :categories,    :through => :interests
  has_many :proficiencies, :dependent => :destroy
  has_many :proglangs,     :through => :proficiencies

  has_many :memberships
  has_many :orgs,          :through => :memberships
  has_one  :picture
  has_many :reviews

  # Name
  validates_presence_of     :name
  validates_length_of       :name,     :within => 0..100  
  # ignore validation for now
  # validates_format_of       :name,     :with => /\A[A-Za-z\-_ \.']+\z/

  # Email
  # validates_presence_of     :email
  # validates_length_of       :email,    :within => 6..100 #r@a.wk
  # validates_uniqueness_of   :email

  # Login
  validates_uniqueness_of   :login

  # Misc info
  validates_numericality_of :units,          :allow_nil => true
  validates_numericality_of :free_hours,     :allow_nil => true
  validates_length_of       :experience,     :maximum => 255
  validates_length_of       :research_blurb, :maximum => 300
  validates_length_of       :url,            :maximum => 255
  validates_numericality_of :year,           :allow_nil => true
  validates_inclusion_of    :year,           :in => (1..4), :allow_nil => true

  # Check that user type is valid
  validates_inclusion_of    :user_type, :in => Types::All, :message => 'is invalid'

  # before_validation :handle_courses
  # before_validation :handle_categories
  # before_validation :handle_proglangs

  attr_accessible :email, :units, :free_hours, :research_blurb, :experience, :summer, :url, :year
  attr_reader :course_names; attr_writer :course_names
  attr_reader :proglang_names; attr_writer :proglang_names
  attr_reader :category_names; attr_writer :category_names

  # Downcases email address
  def email=(value)
    write_attribute :email, (value && !value.empty? ? value.downcase : self.email)
  end

  # @return [UCB::LDAP::Person] for this User
  def ldap_person
    @person ||= UCB::LDAP::Person.find_by_uid(self.login) if self.login
  end

  # @return [String] Full name, as provided by LDAP
  def ldap_person_full_name
    "#{self.ldap_person.firstname} #{self.ldap_person.lastname}".titleize
  end


  # Updates this User's Type based on LDAP information.
  # Raises an error if the user type can't be determined.
  #
  # @param save [Hash] Also commit user type to the database (default +false+)
  # @return [Integer] Inferred user {Types Type}
  #
  def update_user_type(save = false)
    person = self.ldap_person
    if person.nil?
      self.user_type = User::Types::Affiliate
    else
      self.user_type = case
                       when person.berkeleyEduStuUGCode == 'G'
                         User::Types::Grad
                       when person.student?
                         User::Types::Undergrad
                       when person.employee_expired?
                         User::Types::Affiliate
                       when person.employee_academic?
                         User::Types::Faculty
                       when person.employee?
                         User::Types::Staff
                       else
                         User::Types::Affiliate
                       end
    end
    self.update_attribute(:user_type, self.user_type) if save
    self.user_type
  end

  def admin?
    user_type == User::Types::Admin
  end
  # TODO this needs to be a db field.
  def apply?
    user_type == User::Types::Undergrad || user_type == User::Types::Admin
  end
  def post?
    user_type != User::Types::Undergrad || user_type == User::Types::Admin
  end

  # Readable user type
  def user_type_string
    case self.user_type
    when User::Types::Grad
      'Graduate or postdoc'
    when User::Types::Undergrad
      'Undergraduate'
    when User::Types::Faculty
      'Faculty'
    when User::Types::Staff
      'Staff'
    when User::Types::Admin
      'Administrator'
    when User::Types::Affiliate
      'Affiliate'
    else
      'Unknown user type'
      logger.warn "Couldn't find user type string for user type #{self.user_type}"
    end
  end

  # @param add_spaces [Boolean] use ', ' as separator instead of ','
  # @return [String] the 'required course' names taken by this User, e.g. "CS61A,CS61B"
  def course_list_of_user(add_spaces = false)
    course_list = ''
    courses.each do |c|
      course_list << c.name + ','
      course_list << ' ' if add_spaces
    end

    if add_spaces
      course_list[0..(course_list.length - 3)].upcase
    else
      course_list[0..(course_list.length - 2)].upcase
    end
  end

  # @param add_spaces [Boolean] use ', ' as separator instead of ','
  # @return [String] the category names taken by this User, e.g. "robotics,signal processing"
  def category_list_of_user(add_spaces = false)
    category_list = ''
    categories.each do |cat|
      category_list << cat.name + ','
      category_list << ' ' if add_spaces
    end
    
    if add_spaces
      category_list[0..(category_list.length - 3)].downcase
    else
      category_list[0..(category_list.length - 2)].downcase
    end
  end
  
  # @return [String] the 'desired proglang' names taken by this User, e.g. "java,scheme,c++"
  def proglang_list_of_user(add_spaces = false)
    proglang_list = ''
    proglangs.each do |pl|
      proglang_list << pl.name.capitalize + ','
      proglang_list << ' ' if add_spaces
    end
    
    if add_spaces
      proglang_list[0..(proglang_list.length - 3)]
    else
      proglang_list[0..(proglang_list.length - 2)]
    end
  end

  # Makes more sense to handle these for each job
  # def received_jobs_list_of_user
  #   jobs = []
  #   self.applics.all.each do |w|
  #     this_job = Job.find_by_id(w.job_id)
  #     if this_job && w.status == "accepted" then
  #       jobs << this_job
  #     end
  #   end
  #   jobs
  # end
  
  # Parses the textbox list of courses from "CS162,CS61A,EE123"
  # etc. to an enumerable object courses
  def handle_courses(course_names)
    return if !self.apply? || course_names.nil?
    self.courses = []  # eliminates any previous enrollments so as to avoid duplicates
    course_array = []
    course_array = course_names.split(',').uniq if course_names
    course_array.each do |item|
      self.courses << Course.find_or_create_by_name(item.upcase.strip)
    end
  end

  # Parses the textbox list of categories from "signal processing,robotics"
  # etc. to an enumerable object categories
  def handle_categories(category_names)
    return if !self.apply? || category_names
    self.categories = []  # eliminates any previous interests so as to avoid duplicates
    category_array = []
    category_array = category_names.split(',').uniq if category_names
    category_array.each do |cat|
      self.categories << Category.find_or_create_by_name(cat.downcase.strip)
    end
  end
    
  # Parses the textbox list of proglangs from "c++,python"
  # etc. to an enumerable object proglangs
  def handle_proglangs(proglang_names)
    return if !self.apply? || proglang_names.nil?
    self.proglangs = []  # eliminates any previous proficiencies so as to avoid duplicates
    proglang_array = []
    proglang_array = proglang_names.split(',').uniq if proglang_names
    proglang_array.each do |pl|
      self.proglangs << Proglang.find_or_create_by_name(pl.downcase.strip)
    end
  end 

  # @return [Boolean] true if the user has just been activated.
  # @deprecated
  def recently_activated?
    false 
  end

  # @return [User] the user corresponding to given login
  # @deprecated
  def self.authenticate_by_login(loggin)
    # Return user corresponding to login, or nil if there isn't one
    User.find_by_login(loggin)
  end  

  # @deprecated
  def is_faculty?
    user_type == User::Types::Faculty
  end
  protected
    
    # Dynamically assign the value of :email, based on whether this user
    # is marked as faculty or not. This should occur as a before_validation
    # since we want to save a value for :email, not :faculty_email or :student_email.
    # @deprecated
    def handle_email
      self.email = (self.is_faculty? ? Faculty.find_by_name(self.faculty_name).email : self.student_email)
    end
    
    # Dynamically assign the value of :name, based on whether this user
    # is marked as faculty or not. This should occur as a before_validation
    # since we want to save a value for :name, not :faculty_name or :student_name.
    # @deprecated
    def handle_name
      if self.name.nil? || self.name == ""
        self.name = is_faculty? ? faculty_name : student_name
      end
    end
end
