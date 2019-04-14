package level.data;

import electron.renderer.Remote;
import electron.main.Dialog;
import js.node.Path;
import io.FileSystem;
import io.Export;
import io.Imports;
import project.data.Project;
import util.Matrix;
import util.Rectangle;
import util.Vector;

class Level
{
	public var data:LevelData = new LevelData();
	public var layers:Array<Layer> = [];
	public var values:Array<Value> = [];

	//Not Exported
	public var path:String = null;
	public var lastSavedData:String = null;
	public var deleted:Bool = false;
	public var unsavedID:Int;
	public var stack:UndoStack;
	public var unsavedChanges:Bool = false;
	public var currentLayerID:Int = 0;
	public var gridVisible:Bool = true;
	public var camera:Matrix = new Matrix();
	public var cameraInv:Matrix = new Matrix();
	public var project:Project;
	public var zoomRect:Rectangle = null;
	public var zoomTimer:Dynamic;

	public var safeToClose(get, null):Bool;
	public var displayName(get, null):String;
	public var displayNameNoStar(get, null):String;
	public var managerPath(get, null):String;
	public var currentLayer(get, null):Layer;
	public var externallyDeleted(get, null):Bool;
	public var externallyModified(get, null):Bool;
	public var zoom(get, null):Float;

	public static function isUnsavedPath(path:String):Bool
	{
		return path.charAt(0) == "#";
	}

	public function new(project:Project, ?data: Dynamic)
	{
		this.project = project;

		stack = new UndoStack(this);

		if (data == null)
		{
			project.levelDefaultSize.clone(this.data.size);
			values = [];
			for (i in 0...Ogmo.ogmo.project.levelValues.length) values.push(new Value(Ogmo.ogmo.project.levelValues[i]));   
			initLayers();
		}
		else load(data);
		
		centerCamera();
	}
	
	public function initLayers():Void
	{
		layers = [];
		for (i in 0...project.layers.length) layers.push(project.layers[i].createLayer(this, i));
	}
	
	public function load(data:Dynamic):Level
	{
		this.data.loadFrom(data);
		values = Imports.values(data, Ogmo.ogmo.project.levelValues);
		
		initLayers();
		var layers = Imports.contentsArray(data, "layers");
		for (i in 0...layers.length)
		{
			var eid = layers[i]._eid;
			if (eid != null)
			{
				var layer = getLayerByExportID(eid);
				if (layer != null)
					layer.load(layers[i]);
			}
		}

		return this;
	}

	public function storeUndoThenLoad(data:Dynamic):Void
	{
		storeFull(false, false, "Reload from File");
		load(data);
	}

	public function save():Dynamic
	{
		unsavedChanges = false;

		var data:Dynamic = { };
		data._name = "level";
		data._contents = "layers";

		data.saveInto(data);

		Export.values(data, values);

		data.layers = [];
		for (i in 0...layers.length)
			data.layers.push(layers[i].save());

		return data;
	}

	public function attemptClose(action:Void->Void):Void
	{
		if (!unsavedChanges)
		{
			action();
		}
		else
		{
			Popup.open("Close Level", "warning", "Save changes to <span class='monospace'>" + displayNameNoStar + "</span> before closing it?", ["Save and Close", "Discard", "Cancel"], function (i)
			{
				if (i == 0)
				{
					if (doSave())
						action();
				}
				else if (i == 1)
					action();
			});
		}
	}

	/*
			ACTUAL SAVING
	*/

	public function doSave():Bool
	{
		if (path == null)
			return doSaveAs();
		else
		{
			var exists = FileSystem.exists(path);

			Export.level(this, path);

			if (Ogmo.editor.level == this)
				Ogmo.ogmo.updateWindowTitle();

			if (exists)
				Ogmo.editor.levelsPanel.refreshLabelsAndIcons();
			else
				Ogmo.editor.levelsPanel.refresh();

			return true;
		}
	}

	public function doSaveAs():Bool
	{
		Ogmo.ogmo.resetKeys();

		var filters:Dynamic;
		if (Ogmo.ogmo.project.defaultExportMode == ".xml")
			filters = [
				{ name: "XML Level", extensions: [ "xml" ]},
				{ name: "JSON Level", extensions: [ "json" ] }
			];
		else
			filters = [
				{ name: "JSON Level", extensions: [ "json" ] },
				{ name: "XML Level", extensions: [ "xml" ]}
			];

		var file = Dialog.showOpenDialog(Remote.getCurrentWindow(),
		{
			title: "Save Level As...",
			filters: filters,
			defaultPath: Ogmo.ogmo.project.lastSavePath
		});

		if (file != null)
		{
			Ogmo.ogmo.project.lastSavePath = Path.dirname(file);
			path = file;
			Export.level(this, file);

			if (Ogmo.editor.level == this) Ogmo.ogmo.updateWindowTitle();
			Ogmo.editor.levelsPanel.refresh();

			//Update project default export
			if (Ogmo.ogmo.project.defaultExportMode != Path.extname(file))
			{
				Ogmo.ogmo.project.defaultExportMode = Path.extname(file);
				Export.project(Ogmo.ogmo.project, Ogmo.ogmo.project.path);
			}

			return true;
		}
		else
			return false;
	}

	/*
			HELPERS
	*/

	public function getLayerByExportID(exportID:String): Layer
	{
		for (i in 0...layers.length) if (layers[i].template.exportID == exportID) return layers[i];
		return null;
	}

	public function insideLevel(pos: Vector):Bool
	{
		return pos.x >= 0 && pos.x < data.size.x && pos.y >= 0 && pos.y < data.size.y;
	}

	/*
			UNDO STATE HELPERS
	*/

	public function store(description:String):Void
	{
		stack.store(description);
	}

	public function storeFull(freezeRight:Bool, freezeBottom:Bool, description:String):Void
	{
		stack.storeFull(freezeRight, freezeBottom, description);
	}

	/*
			TRANSFORMATIONS
	*/

	public function resize(newSize: Vector, shift: Vector):Void
	{
		if (!data.size.equals(newSize))
		{
			for (i in 0...layers.length) layers[i].resize(newSize.clone(), shift.clone());
			data.size = newSize.clone();
		}
	}

	public function shift(amount: Vector):Void
	{
		for (i in 0...layers.length) layers[i].shift(amount.clone());
	}

	/*
			CAMERA
	*/

	public function updateCameraInverse():Void
	{
		camera.inverse(cameraInv);
	}

	public function centerCamera():Void
	{
		camera.setIdentity();
		moveCamera(data.size.x / 2, data.size.y / 2);
		updateCameraInverse();
		Ogmo.editor.dirty();

		Ogmo.editor.updateZoomReadout();
		if (Ogmo.editor.level == this) Ogmo.editor.handles.refresh();
	}

	public function moveCamera(x:Float, y:Float):Void
	{
		if (x != 0 || y != 0)
		{
			camera.translate(-x, -y);
			updateCameraInverse();
			Ogmo.editor.dirty();
		}
	}

	public function zoomCamera(zoom:Float):Void
	{
		setZoomRect(zoom);

		camera.scale(1 + .1 * zoom, 1 + .1 * zoom);
		updateCameraInverse();
		Ogmo.editor.dirty();

		Ogmo.editor.updateZoomReadout();
		Ogmo.editor.handles.refresh();
	}

	public function zoomCameraAt(zoom:Float, x:Float, y:Float):Void
	{
		setZoomRect(zoom);

		moveCamera(x, y);
		camera.scale(1 + .1 * zoom, 1 + .1 * zoom);
		moveCamera(-x, -y);
		updateCameraInverse();
		Ogmo.editor.dirty();

		Ogmo.editor.updateZoomReadout();
		Ogmo.editor.handles.refresh();
	}

	public function setZoomRect(zoom:Float):Void
	{
		if (zoom < 0 && zoomRect == null)
		{
			var topLeft = Ogmo.editor.getTopLeft();
			var bottomRight = Ogmo.editor.getBottomRight();
			zoomRect = new Rectangle(topLeft.x, topLeft.y, bottomRight.x - topLeft.x, bottomRight.y - topLeft.y);
		}

		if (zoomTimer != null) untyped clearTimeout(zoomTimer);
		zoomTimer = untyped setTimeout(clearZoomRect, 500);
	}

	public function clearZoomRect():Void
	{
		Ogmo.editor.level.zoomRect = null;
		Ogmo.editor.overlayDirty();
	}

	function get_safeToClose():Bool
	{
		return !unsavedChanges && stack.undoStates.length == 0 && stack.redoStates.length == 0 && path != null;
	}

	function get_displayName():String
	{
		var str = displayNameNoStar;
		if (unsavedChanges)
			str += "*";

		return str;
	}

	function get_displayNameNoStar():String
	{
		var str:String;
		if (path == null)
			str = "Unsaved Level " + (unsavedID + 1);
		else
			str = Path.basename(path);

		return str;
	}

	function get_managerPath():String
	{
		if (path == null)
			return "#" + unsavedID;
		else
			return path;
	}

	function get_currentLayer():Layer
	{
		return layers[currentLayerID];
	}

	function get_externallyDeleted():Bool
	{
		return path != null && !FileSystem.exists(path);
	}

	function get_externallyModified():Bool
	{
		return path != null && FileSystem.exists(path) && FileSystem.loadString(path) != lastSavedData;
	}

	function get_zoom():Float
	{
		return camera.a;
	}
}