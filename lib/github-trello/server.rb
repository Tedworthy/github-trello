require "json"
require "sinatra/base"
require "github-trello/version"
require "github-trello/http"

module GithubTrello
  class Server < Sinatra::Base
    post "/posthook" do
      config, http_users = self.class.config, self.class.http_users

      payload = JSON.parse(request.body.read)

      # Get the Trello board ID for the repository
      board_id = config["board_ids"][payload["repository"]["name"]]
      unless board_id
        puts "[ERROR] Commit from #{payload["repository"]["name"]} but no board_id entry found in config"
        return
      end

      # Check for blacklist/whitelist settings
      branch = payload["ref"].gsub("refs/heads/", "")
      if config["blacklist_branches"] and config["blacklist_branches"].include?(branch)
        return
      elsif config["whitelist_branches"] and !config["whitelist_branches"].include?(branch)
        return
      end

      payload["commits"].each do |commit|
        # Get relevant HTTP object for commit author
        http = http_users[commit["author"]["name"]]
        next unless http

        # Check for matches of commands in the set of possible actions
        matches = commit["message"].scan(/((case|card|closes?|archives?|fix(es)?|starts?|doing|done) ([0-9]+))/i)
        next if matches.empty?

        matches.each do |match|
          # Get portions of the match
          action = match[1]
          card_no = match[3].to_i

          # Check that the card specified exists in Trello
          card = http.get_card(board_id, card_no)
          unless card
            puts "[ERROR] Cannot find card matching ID #{card_no}"
            next
          end

          card = JSON.parse(card)

          # Add the commit comment
          message = "#{commit["author"]["name"]}: #{commit["message"]}\n\n[#{branch}] #{commit["url"]}"
          message.gsub!(/\(\)$/, "")
          matches.each do |m|
            message.gsub!(m[0], "")
          end

          http.add_comment(card["id"], message)

          # Determine the action to take
          update_config = case action.downcase
            when "case", "card", "doing", "start", "starts" then config["on_start"]
            when "close", "fix", "closes", "fixes", "done" then config["on_close"]
            when "archive", "archives" then {:archive => true}
          end

          next unless update_config.is_a?(Hash)

          # Modify it if needed
          to_update = {}

          if update_config["move_to"].is_a?(Hash)
            move_to = update_config["move_to"][payload["repository"]["name"]]
          else
            move_to = update_config["move_to"]
          end

          unless card["idList"] == move_to
            to_update[:idList] = move_to
          end

          if !card["closed"] and update_config["archive"]
            to_update[:closed] = true
          end

          unless to_update.empty?
            http.update_card(card["id"], to_update)
          end
        end
      end

      ""
    end

    post "/deployed/:repo" do
      config, http_deploy = self.class.config, self.class.http_deploy
      if !config["on_deploy"]
        raise "Deploy triggered without a on_deploy config specified"
      elsif !config["on_close"] or !config["on_close"]["move_to"]
        raise "Deploy triggered and either on_close config missed or move_to is not set"
      end

      update_config = config["on_deploy"]

      to_update = {}
      if update_config["move_to"] and update_config["move_to"][params[:repo]]
        to_update[:idList] = update_config["move_to"][params[:repo]]
      end

      if update_config["archive"]
        to_update[:closed] = true
      end

      if config["on_close"]["move_to"].is_a?(Hash)
        target_board = config["on_close"]["move_to"][params[:repo]]
      else
        target_board = config["on_close"]["move_to"]
      end

      cards = JSON.parse(http_deploy.get_cards(target_board))
      cards.each do |card|
        http_deploy.update_card(card["id"], to_update)
      end

      ""
    end

    get "/" do
      ""
    end

    def self.config=(config)
      @config = config
      @http_users = Hash.new
      config["users"].each do |user, auth|
        puts user
        puts auth
        @http_users[user] = GithubTrello::HTTP.new(auth["oauth_token"], auth["api_key"])
      end
      @http_deploy = GithubTrello::HTTP.new(config["deploy_oauth_token"], config["deploy_api_key"])
    end

    def self.config; @config end
    def self.http_users; @http_users end
    def self.http_deploy; @http_deploy end
  end
end
