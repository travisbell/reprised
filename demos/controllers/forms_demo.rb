# frozen_string_literal: true

class Demos
  # ActionView's form helpers in ERB, with their blocks captured (`<%= form_tag(path) do %>`), and a block helper of
  # the controller's own built on capture. A form that doesn't validate is shown again with its errors (a 422); one
  # that does redirects, so reloading the page doesn't post it twice.
  class FormsDemo < Reprised::Controller
    Suggestion = Data.define(:title, :year, :genre, :notes, :seen, :at)

    # The latest suggestions, newest first, in this process.
    class Suggestions
      include Enumerable

      def initialize(*suggestions)
        @suggestions = suggestions
      end

      def add(suggestion)
        @suggestions.unshift(suggestion)
        @suggestions.pop while @suggestions.size > 20
      end

      def each(&) = @suggestions.each(&)
    end

    SUGGESTIONS = Suggestions.new(Suggestion.new("Safety Last!", 1923, "Comedy", "The clock scene.", true, Time.now))

    FIELDS = [:title, :year, :genre, :notes, :seen].freeze

    # The helpers are this controller's: the other demos don't have them.
    helpers do
      # A labelled field, with its error, around what the block renders. capture renders the block to a String.
      def field(name, label, &block)
        error = @errors[name]
        tag.div(class: ["field", ("invalid" if error)]) do
          safe_join([label_tag(name, label), capture(&block), (tag.p(error, class: "error") if error)].compact)
        end
      end
    end

    get "/forms" do
      show_forms
    end

    post "/forms/suggestions" do
      form = FIELDS.to_h { [it, params[it].to_s.strip] }
      errors = validate(form)
      halt(422, show_forms(form:, errors:)) unless errors.empty?

      SUGGESTIONS.add(Suggestion.new(**form, year: Integer(form[:year], 10), seen: form[:seen] == "1", at: Time.now))
      redirect("/forms#suggestions")
    end

    # A multipart upload: params[:poster] is the file's Hash, with its :filename, :type, and :tempfile.
    post "/forms/poster" do
      poster = params[:poster]
      halt(422, show_forms(upload_error: "Choose a file to upload")) unless poster.is_a?(Hash) && poster[:tempfile]

      show_forms(upload: { filename: poster[:filename], type: poster[:type], size: poster[:tempfile].size })
    end

    private

    def show_forms(form: {}, errors: {}, upload: nil, upload_error: nil)
      @title = "Forms"
      @form = form
      @errors = errors
      erb(:forms, locals: { upload:, upload_error:, suggestions: SUGGESTIONS })
    end

    def validate(form)
      errors = {}
      errors[:title] = "Give the movie's title" if form[:title].empty?
      year = Integer(form[:year], 10, exception: false)
      errors[:year] = "A year from 1888 to #{Time.now.year}" unless year&.between?(1888, Time.now.year)
      errors[:genre] = "Choose a genre" unless GENRES.include?(form[:genre])
      errors[:notes] = "Keep it under 280 characters" if form[:notes].length > 280
      errors
    end
  end
end
