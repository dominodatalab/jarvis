# Description:
#   Messing with the JIRA REST API
#
# Configuration:
#   HUBOT_JIRA_URL
#   HUBOT_JIRA_USER
#   HUBOT_JIRA_PASSWORD
#   Optional environment variables:
#   HUBOT_JIRA_USE_V2 (defaults to "true", set to "false" for JIRA earlier than 5.0)
#   HUBOT_JIRA_MAXLIST
#   HUBOT_JIRA_ISSUEDELAY
#   HUBOT_JIRA_IGNOREUSERS
#
# Commands:
#   <Project Key>-<Issue ID> - Displays information about the JIRA ticket (if it exists)
#   hubot show watchers for <Issue Key> - Shows watchers for the given JIRA issue
#   hubot search for <JQL> - Search JIRA with JQL
#   hubot save filter <JQL> as <name> - Save JIRA JQL query as filter in the brain
#   hubot use filter <name> - Use a JIRA filter from the brain
#   hubot show filter(s) - Show all JIRA filters
#   hubot show filter <name> - Show a specific JIRA filter
#
# Author:
#   Original by codec; modifications by marks
#
# Dependencies:
#   "underscore": "*"

_ = require('underscore')

class IssueFilters
  constructor: (@robot) ->
    @cache = []

    @robot.brain.on 'loaded', =>
      jqls_from_brain = @robot.brain.data.jqls
      # only overwrite the cache from redis if data exists in redis
      if jqls_from_brain
        @cache = jqls_from_brain

  add: (filter) ->
    @cache.push filter
    @robot.brain.data.jqls = @cache

  delete: (name) ->
    result = []
    @cache.forEach (filter) ->
      if filter.name.toLowerCase() isnt name.toLowerCase()
        result.push filter

    @cache = result
    @robot.brain.data.jqls = @cache

  get: (name) ->
    result = null

    @cache.forEach (filter) ->
      if filter.name.toLowerCase() is name.toLowerCase()
        result = filter

    result
  all: ->
    return @cache

class IssueFilter
  constructor: (@name, @jql) ->
    return {name: @name, jql: @jql}


# keeps track of recently displayed issues, to prevent spamming
class RecentIssues
  constructor: (@maxage) ->
    @issues = []

  cleanup: ->
    for issue,time of @issues
      age = Math.round(((new Date).getTime() - time) / 1000)
      if age > @maxage
        delete @issues[issue]
    0

  contains: (issue) ->
    @cleanup()
    @issues[issue]?

  add: (issue, time = (new Date).getTime()) ->
    @issues[issue] = time


module.exports = (robot) ->
  filters = new IssueFilters robot

  useV2 = process.env.HUBOT_JIRA_USE_V2 isnt 'false'
  # max number of issues to list during a search
  maxlist = process.env.HUBOT_JIRA_MAXLIST || 10
  # how long (seconds) to wait between repeating the same JIRA issue link
  issuedelay = process.env.HUBOT_JIRA_ISSUEDELAY || 10
  # array of users that are ignored
  ignoredusers = _.compact (process.env.HUBOT_JIRA_IGNOREUSERS || '').split(',')

  recentissues = new RecentIssues issuedelay

  get = (msg, where, cb) ->
    endpoint = "#{process.env.HUBOT_JIRA_URL}/rest/api/latest/#{where}"
    console.log endpoint

    httprequest = msg.http(endpoint)
    if (process.env.HUBOT_JIRA_USER)
      credentials = "#{process.env.HUBOT_JIRA_USER}:#{process.env.HUBOT_JIRA_PASSWORD}"
      authdata = new Buffer(credentials).toString('base64')
      httprequest = httprequest.header('Authorization', "Basic #{authdata}")
    httprequest.get() (err, res, body) ->
      try
        response = JSON.parse(body)
        if err || response.errors? then cb null else cb response
      catch e
        console.log 'Response from JIRA API was unparseable as JSON!'
        cb null

  watchers = (msg, issue, cb) ->
    get msg, "issue/#{issue}/watchers", (watchers) ->
      return if watchers is null

      cb _.pluck(watchers.watchers, 'displayName').join(', ')

  info = (msg, issue, cb) ->
    get msg, "issue/#{issue}", (issues) ->
      return if issues is null

      getFixVersions = (fixVersions) ->
        if fixVersions.length then _.pluck(fixVersions, 'name').join(', ') else 'no fix version'

      if useV2
        issue =
          key: issues.key
          summary: issues.fields.summary
          assignee: issues.fields.assignee?.displayName || 'no assignee'
          status: issues.fields.status.name
          fixVersion: getFixVersions(issues.fields.fixVersions || [])
          url: "#{process.env.HUBOT_JIRA_URL}/browse/#{issues.key}"
      else
        issue =
          key: issues.key
          summary: issues.fields.summary.value
          assignee: issues.fields.assignee?.value?.displayName || 'no assignee'
          status: issues.fields.status.value.name
          fixVersion: getFixVersions(issues.fields.fixVersions?.value || [])
          url: "#{process.env.HUBOT_JIRA_URL}/browse/#{issues.key}"

      cb "[#{issue.key}] #{issue.summary}. #{issue.assignee()} / #{issue.status}, #{issue.fixVersion()} #{issue.url}"

  search = (msg, jql, cb) ->
    get msg, "search/?jql=#{escape(jql)}", (result) ->
      return if result is null

      resultText = "I found #{result.total} issues for your search. #{process.env.HUBOT_JIRA_URL}/secure/IssueNavigator.jspa?reset=true&jqlQuery=#{escape(jql)}"
      if result.issues.length <= maxlist
        cb resultText
        result.issues.forEach (issue) ->
          info msg, issue.key, (info) ->
            cb info
      else
        cb "#{resultText} (too many to list)"

  robot.respond /(show )?watchers (for )?(\w+-[0-9]+)/i, (msg) ->
    if msg.message.user.id is robot.name
      return

    watchers msg, msg.match[3], (text) ->
      msg.send text

  robot.respond /search (for )?(.*)/i, (msg) ->
    if msg.message.user.id is robot.name
      return

    search msg, msg.match[2], (text) ->
      msg.reply text

  robot.hear /(?:[^\w-]|^)([a-z]+-\d+)(?=\W|$)/ig, (msg) ->
    if msg.message.user.id is robot.name
      return

    if (ignoredusers.some (user) -> user is msg.message.user.name)
      console.log "ignoring user #{msg.message.user.name} due to blacklist"
      return

    tickets = _.uniq _.map(msg.match, (text) => text.replace /^\W/, '' )
    for ticket in tickets
      get msg, "issue/#{ticket}", (ticket) ->
        return if ticket is null

        ticket_fields = []
        ticket_fields.push(title: 'Type', value:"#{ticket.fields.issuetype.name}", short: true) if ticket.fields?.issuetype?.name?
        ticket_fields.push(title: 'Status', value:"#{ticket.fields.status.name}", short: true) if ticket.fields?.status?.name?
        ticket_fields.push(title: 'Priority', value:"#{ticket.fields.prority.name}", short: true) if ticket.fields?.prority?.name?
        ticket_fields.push(title: 'Assignee', value:"#{ticket.fields.assignee.displayName}", short: true) if ticket.fields?.assignee?.displayName?
        ticket_fields.push(title: 'Due Date', value:"#{ticket.fields.duedate}", short: true) if ticket.fields?.duedate?

        payload =
          message: msg.message
          content:
            title: "<#{process.env.HUBOT_JIRA_URL}/browse/#{ticket.key}|#{ticket.key}: #{ticket.fields.summary}>"
            author_name: ticket.fields.reporter.displayName + " (Reporter)"
            author_icon: "#{ticket.fields.issuetype.iconUrl}&format=png"
            text: ticket.fields.description
            fallback: 'JIRA issue #{ticket.key} (#{ticket.fields.summary})'
            fields: ticket_fields
            mrkdwn_in: ['text', 'fields']

        robot.emit 'slack-attachment', payload

  robot.respond /save filter (.*) as (.*)/i, (msg) ->
    filter = filters.get msg.match[2]

    if filter
      filters.delete filter.name
      msg.reply "Updated filter #{filter.name} for you"

    filter = new IssueFilter msg.match[2], msg.match[1]
    filters.add filter

  robot.respond /delete filter (.*)/i, (msg) ->
    filters.delete msg.match[1]

  robot.respond /(use )?filter (.*)/i, (msg) ->
    name = msg.match[2]
    filter = filters.get name

    unless filter
      msg.reply "Sorry, could not find filter #{name}"
      return

    search msg, filter.jql, (text) ->
      msg.reply text

  robot.respond /(show )?filter(s)? ?(.*)?/i, (msg) ->
    unless filters.all().length
      msg.reply "Sorry, I don't remember any filters."
      return

    if msg.match[3] is undefined
      msg.reply "I remember #{filters.all().length} filters"
      filters.all().forEach (filter) ->
        msg.reply "#{filter.name}: #{filter.jql}"
    else
      filter = filters.get msg.match[3]
      msg.reply "#{filter.name}: #{filter.jql}"
