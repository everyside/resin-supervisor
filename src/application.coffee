_ = require 'lodash'
url = require 'url'
Lock = require 'rwlock'
knex = require './db'
path = require 'path'
config = require './config'
dockerUtils = require './docker-utils'
Promise = require 'bluebird'
utils = require './utils'
tty = require './lib/tty'
logger = require './lib/logger'
{ cachedResinApi } = require './request'
device = require './device'
lockFile = Promise.promisifyAll(require('lockfile'))
bootstrap = require './bootstrap'

{ docker } = dockerUtils

logTypes =
	stopApp:
		eventName: 'Application kill'
		humanName: 'Killing application'
	stopAppSuccess:
		eventName: 'Application stop'
		humanName: 'Killed application'
	stopAppError:
		eventName: 'Application stop error'
		humanName: 'Failed to kill application'

	downloadApp:
		eventName: 'Application download'
		humanName: 'Downloading application'
	downloadAppSuccess:
		eventName: 'Application downloaded'
		humanName: 'Downloaded application'
	downloadAppError:
		eventName: 'Application download error'
		humanName: 'Failed to download application'

	installApp:
		eventName: 'Application install'
		humanName: 'Installing application'
	installAppSuccess:
		eventName: 'Application installed'
		humanName: 'Installed application'
	installAppError:
		eventName: 'Application install error'
		humanName: 'Failed to install application'

	startApp:
		eventName: 'Application start'
		humanName: 'Starting application'
	startAppSuccess:
		eventName: 'Application started'
		humanName: 'Started application'
	startAppError:
		eventName: 'Application started'
		humanName: 'Failed to start application'

	updateApp:
		eventName: 'Application update'
		humanName: 'Updating application'
	updateAppError:
		eventName: 'Application update error'
		humanName: 'Failed to update application'

logSystemEvent = (logType, app, error) ->
	message = "#{logType.humanName} '#{app.imageId}'"
	if error?
		# Report the message from the original cause to the user.
		errMessage = error.json
		if _.isEmpty(errMessage)
			errMessage = error.reason
		if _.isEmpty(errMessage)
			errMessage = error.message
		if _.isEmpty(errMessage)
			errMessage = 'Unknown cause'
		message += " due to '#{errMessage}'"
	logger.log({ message, isSystem: true })
	utils.mixpanelTrack(logType.eventName, {app, error})
	return

application = {}

application.kill = kill = (app) ->
	logSystemEvent(logTypes.stopApp, app)
	device.updateState(status: 'Stopping')
	container = docker.getContainer(app.containerId)
	tty.stop(app)
	.catch (err) ->
		console.error('Error stopping tty', err)
		return # Even if stopping the tty fails we want to finish stopping the container
	.then ->
		container.stopAsync()
	.then ->
		container.removeAsync()
	# Bluebird throws OperationalError for errors resulting in the normal execution of a promisified function.
	.catch Promise.OperationalError, (err) ->
		# Get the statusCode from the original cause and make sure statusCode its definitely a string for comparison
		# reasons.
		statusCode = '' + err.statusCode
		# 304 means the container was already stopped - so we can just remove it
		if statusCode is '304'
			return container.removeAsync()
		# 404 means the container doesn't exist, precisely what we want! :D
		if statusCode is '404'
			return
		throw err
	.tap ->
		lockFile.unlockAsync(lockPath(app))
	.tap ->
		logSystemEvent(logTypes.stopAppSuccess, app)
		app.containerId = null
		knex('app').update(app).where(appId: app.appId)
	.catch (err) ->
		logSystemEvent(logTypes.stopAppError, app, err)
		throw err

isValidPort = (port) ->
	maybePort = parseInt(port, 10)
	return parseFloat(port) is maybePort and maybePort > 0 and maybePort < 65535

fetch = (app) ->
	docker.getImage(app.imageId).inspectAsync()
	.catch (error) ->
		logSystemEvent(logTypes.downloadApp, app)
		device.updateState(status: 'Downloading')
		dockerUtils.fetchImageWithProgress app.imageId, (progress) ->
			device.updateState(download_progress: progress.percentage)
		.then ->
			logSystemEvent(logTypes.downloadAppSuccess, app)
			device.updateState(download_progress: null)
			docker.getImage(app.imageId).inspectAsync()
		.catch (err) ->
			logSystemEvent(logTypes.downloadAppError, app, err)
			throw err

application.start = start = (app) ->
	volumes =
		'/data': {}
		'/lib/modules': {}
		'/lib/firmware': {}
		'/run/dbus': {}
	binds = [
		'/resin-data/' + app.appId + ':/data'
		'/lib/modules:/lib/modules'
		'/lib/firmware:/lib/firmware'
		'/run/dbus:/run/dbus'
		'/run/dbus:/host_run/dbus'
		'/var/run/docker.sock:/run/docker.sock'
		'/var/run/docker.sock:/host_run/docker.sock'
		'/etc/resolv.conf:/etc/resolv.conf:rw'
	]
	device.getDeviceType()
	.then (deviceType) ->
		if deviceType.match(/^raspberry-pi/)?
			volumes['/boot'] = {}
			binds.push('/boot:/boot')
	.catch (err) ->
		console.log('Could not determine device type: ', err)
	.then ->
		# Parse the env vars before trying to access them, that's because they have to be stringified for knex..
		JSON.parse(app.env)
	.then (env) ->
		if env.PORT?
			portList = env.PORT
			.split(',')
			.map((port) -> port.trim())
			.filter(isValidPort)

		if app.containerId?
			# If we have a container id then check it exists and if so use it.
			container = docker.getContainer(app.containerId)
			containerPromise = container.inspectAsync().return(container)
		else
			containerPromise = Promise.rejected()

		# If there is no existing container then create one instead.
		containerPromise.catch ->
			fetch(app)
			.then (imageInfo) ->
				logSystemEvent(logTypes.installApp, app)
				device.updateState(status: 'Installing')

				ports = {}
				if portList?
					portList.forEach (port) ->
						ports[port + '/tcp'] = {}

				if imageInfo?.Config?.Cmd
					cmd = imageInfo.Config.Cmd
				else
					cmd = [ '/bin/bash', '-c', '/start' ]

				docker.createContainerAsync(
					Image: app.imageId
					Cmd: cmd
					Tty: true
					Volumes: volumes
					Env: _.map env, (v, k) -> k + '=' + v
					ExposedPorts: ports
				)
				.tap ->
					logSystemEvent(logTypes.installAppSuccess, app)
				.catch (err) ->
					logSystemEvent(logTypes.installAppError, app, err)
					throw err
		.tap (container) ->
			# Update the app info the moment we create the container, even if then starting the container fails. This
			# stops issues with constantly creating new containers for an image that fails to start.
			app.containerId = container.id
			knex('app').update(app).where(appId: app.appId)
			.then (affectedRows) ->
				knex('app').insert(app) if affectedRows == 0
		.tap (container) ->
			logSystemEvent(logTypes.startApp, app)
			device.updateState(status: 'Starting')
			ports = {}
			if portList?
				portList.forEach (port) ->
					ports[port + '/tcp'] = [ HostPort: port ]
			container.startAsync(
				Privileged: true
				NetworkMode: 'host'
				PortBindings: ports
				Binds: binds
			)
			.catch (err) ->
				statusCode = '' + err.statusCode
				# 304 means the container was already started, precisely what we want :)
				if statusCode is '304'
					return
				logSystemEvent(logTypes.startAppError, app, err)
				throw err
			.then ->
				device.updateState(commit: app.commit)
				logger.attach(app)
	.tap ->
		logSystemEvent(logTypes.startAppSuccess, app)
	.finally ->
		device.updateState(status: 'Idle')

getEnvironment = do ->
	envApiEndpoint = url.resolve(config.apiEndpoint, '/environment')

	return (appId, deviceId, apiKey) ->

		requestParams = _.extend
			method: 'GET'
			url: "#{envApiEndpoint}?deviceId=#{deviceId}&appId=#{appId}&apikey=#{apiKey}"
		, cachedResinApi.passthrough

		cachedResinApi._request(requestParams)
		.catch (err) ->
			console.error("Failed to get environment for device #{deviceId}, app #{appId}. #{err}")
			throw err

lockPath = (app) ->
	appId = app.appId ? app
	return "/mnt/root/resin-data/#{appId}/resin-updates.lock"

# At boot, all apps should be unlocked *before* start to prevent a deadlock
application.unlockAndStart = unlockAndStart = (app) ->
	lockFile.unlockAsync(lockPath(app))
	.then ->
		start(app)

ENOENT = (err) -> err.code is 'ENOENT'

application.lockUpdates = lockUpdates = do ->
	_lock = new Lock()
	_writeLock = Promise.promisify(_lock.async.writeLock)
	return (app, force) ->
		lockName = lockPath(app)
		_writeLock(lockName)
		.tap (release) ->
			if force != true
				lockFile.lockAsync(lockName)
				.catch ENOENT, _.noop
				.catch (err) ->
					release()
					throw new Error("Updates are locked: #{err.message}")
		.disposer (release) ->
			Promise.try ->
				lockFile.unlockAsync(lockName) if force != true
			.finally ->
				release()

joinErrorMessages = (failures) ->
	s = if failures.length > 1 then 's' else ''
	messages = _.map failures, (err) ->
		err.message or err
	"#{failures.length} error#{s}: #{messages.join(' - ')}"

# Example callback function to enable/disable vpn
# enableVpn = (val) ->
# 	if val == '1' then console.log('Enabling VPN') else console.log('Disabling VPN')

specialActionEnvVars = {
	'RESIN_OVERRIDE_LOCK': null
	# @Praneeth: maybe add your vars here with a callback as value? e.g:
	# 'RESIN_ENABLE_VPN': enableVpn
}

UPDATE_IDLE = 0
UPDATE_UPDATING = 1
UPDATE_REQUIRED = 2

updateStatus =
	state: UPDATE_IDLE
	failed: 0
	forceNext: false
application.update = update = (force) ->
	if updateStatus.state isnt UPDATE_IDLE
		# Mark an update required after the current.
		updateStatus.forceNext = force
		updateStatus.state = UPDATE_REQUIRED
		return
	updateStatus.state = UPDATE_UPDATING
	bootstrap.done.then ->
		Promise.all([
			knex('config').select('value').where(key: 'apiKey')
			knex('config').select('value').where(key: 'uuid')
			knex('app').select()
		])
		.then ([ [ apiKey ], [ uuid ], apps ]) ->
			apiKey = apiKey.value
			uuid = uuid.value

			deviceId = device.getID()

			remoteApps = cachedResinApi.get
				resource: 'application'
				options:
					select: [
						'id'
						'git_repository'
						'commit'
					]
					filter:
						commit: $ne: null
						device:
							uuid: uuid
				customOptions:
					apikey: apiKey

			Promise.join deviceId, remoteApps, (deviceId, remoteApps) ->
				return Promise.map remoteApps, (remoteApp) ->
					getEnvironment(remoteApp.id, deviceId, apiKey)
					.then (environment) ->
						remoteApp.environment_variable = environment
						return remoteApp
			.then (remoteApps) ->
				remoteAppEnvs = {}
				remoteApps = _.map remoteApps, (app) ->
					env =
						RESIN_DEVICE_UUID: uuid
						RESIN: '1'
						USER: 'root'

					if app.environment_variable?
						_.extend(env, app.environment_variable)
					remoteAppEnvs[app.id] = env
					env = _.pick env, (val, key) ->
						!_.includes(key, _.keys(specialActionEnvVars))
					return {
						appId: '' + app.id
						commit: app.commit
						imageId: "#{config.registryEndpoint}/#{path.basename(app.git_repository, '.git')}/#{app.commit}"
						env: JSON.stringify(env) # The env has to be stored as a JSON string for knex
					}

				remoteApps = _.indexBy(remoteApps, 'appId')
				remoteAppIds = _.keys(remoteApps)

				# @Praneeth: looks like this might be a good place to run the special functions,
				# like turning vpn on/off if remoteAppEnvs has the corresponding variable.
				_.map specialActionEnvVars, (specialActionCallback, key) ->
					_.map remoteAppIds, (appId) ->
						if remoteAppEnvs[appId][key]? && specialActionCallback?
							specialActionCallback(remoteAppEnvs[appId][key])

				apps = _.indexBy(apps, 'appId')
				localApps = _.mapValues apps, (app) ->
					_.pick(app, [ 'appId', 'commit', 'imageId', 'env' ])
				localAppIds = _.keys(localApps)

				toBeRemoved = _.difference(localAppIds, remoteAppIds)
				toBeInstalled = _.difference(remoteAppIds, localAppIds)

				toBeUpdated = _.intersection(remoteAppIds, localAppIds)
				toBeUpdated = _.filter toBeUpdated, (appId) ->
					return !_.isEqual(remoteApps[appId], localApps[appId])

				toBeDownloaded = _.filter toBeUpdated, (appId) ->
					return !_.isEqual(remoteApps[appId].imageId, localApps[appId].imageId)
				toBeDownloaded = _.union(toBeDownloaded, toBeInstalled)

				allAppIds = _.union(localAppIds, remoteAppIds)

				Promise.map allAppIds, (appId) ->
					Promise.try ->
						fetch(remoteApps[appId]) if _.includes(toBeDownloaded, appId)
					.then ->
						if _.includes(toBeRemoved, appId)
							Promise.using lockUpdates(apps[appId], force), ->
								# We get the app from the DB again in case someone restarted it
								# (which would have changed its containerId)
								knex('app').select().where({ appId })
								.then ([ app ]) ->
									if !app?
										throw new Error('App not found')
									kill(app)
								.then ->
									knex('app').where('appId', appId).delete()
							.catch (err) ->
								logSystemEvent(logTypes.updateAppError, app, err)
								throw err
						else if _.includes(toBeInstalled, appId)
							app = remoteApps[appId]
							start(app)
						else if _.includes(toBeUpdated, appId)
							localApp = apps[appId]
							app = remoteApps[appId]
							logSystemEvent(logTypes.updateApp, app) if localApp.imageId == app.imageId
							forceThisApp = remoteAppEnvs[appId]['RESIN_OVERRIDE_LOCK'] == '1'
							Promise.using lockUpdates(localApp, force || forceThisApp), ->
								knex('app').select().where({ appId })
								.then ([ localApp ]) ->
									if !localApp?
										throw new Error('App not found')
									kill(localApp)
								.then ->
									start(app)
							.catch (err) ->
								logSystemEvent(logTypes.updateAppError, app, err)
								throw err
					.catch(_.identity)
		.filter(_.isError)
		.then (failures) ->
			throw new Error(joinErrorMessages(failures)) if failures.length > 0
		.then ->
			updateStatus.failed = 0
			# We cleanup here as we want a point when we have a consistent apps/images state, rather than potentially at a
			# point where we might clean up an image we still want.
			dockerUtils.cleanupContainersAndImages()
		.catch (err) ->
			updateStatus.failed++
			if updateStatus.state is UPDATE_REQUIRED
				console.log('Updating failed, but there is already another update scheduled immediately: ', err)
				return
			delayTime = Math.min(updateStatus.failed * 500, 30000)
			# If there was an error then schedule another attempt briefly in the future.
			console.log('Scheduling another update attempt due to failure: ', delayTime, err)
			setTimeout(update, delayTime, force)
		.finally ->
			device.updateState(status: 'Idle')
			if updateStatus.state is UPDATE_REQUIRED
				# If an update is required then schedule it
				setTimeout(update, 1, updateStatus.forceNext)
		.finally ->
			# Set the updating as finished in its own block, so it never has to worry about other code stopping this.
			updateStatus.state = UPDATE_IDLE

module.exports = (uuid) ->
	logger.init(
		dockerSocket: config.dockerSocket
		pubnub: config.pubnub
		channel: "device-#{uuid}-logs"
	)
	return application
