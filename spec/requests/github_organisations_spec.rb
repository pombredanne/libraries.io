require "rails_helper"

describe "ExploreController" do
  describe "GET /github/organisations", type: :request do
    it "renders successfully when logged out" do
      visit github_organisations_path
      expect(page).to have_content 'Organisations'
    end
  end
end
